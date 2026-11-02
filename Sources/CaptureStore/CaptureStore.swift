import Foundation
import ProxyCore

public struct CaptureSession: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var eventCount: Int
    /// When the newest event happened; nil for an empty session.
    public var lastEventAt: Date?
    /// Events per kind (`http`, `mqtt`, `websocket`, `tunnel`, `tls`).
    public var kindCounts: [String: Int]

    public init(id: UUID, name: String, createdAt: Date, eventCount: Int, lastEventAt: Date? = nil, kindCounts: [String: Int] = [:]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.eventCount = eventCount
        self.lastEventAt = lastEventAt
        self.kindCounts = kindCounts
    }
}

/// A capture event as stored, with its row id (stable ordering) and session.
public struct StoredCaptureEvent: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var sessionID: UUID
    public var kind: String
    public var host: String
    public var summary: String
    /// When the event happened (request start, packet time), or when it was recorded.
    public var timestamp: Date
    public var event: CaptureEvent
}

/// Persists capture events in SQLite, grouped into sessions, with FTS5 search.
///
/// It is a `CaptureSink`, so it can be handed straight to `HTTPProxyServer` or `MQTTForwarder`;
/// events land in `currentSession`. All access is serialized, so it is safe from any thread.
public final class CaptureStore: CaptureSink, @unchecked Sendable {
    private let database: SQLiteDatabase
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var _currentSession: UUID
    private var _lastError: Error?

    /// Opens or creates the store at `path` (`":memory:"` for a throwaway store). A session named
    /// `sessionName` is started for incoming events.
    public init(path: String, sessionName: String = "Session") throws {
        database = try SQLiteDatabase(path: path)
        try database.execute("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA synchronous = NORMAL;")
        try Self.migrate(database)
        _currentSession = UUID()
        try insertSession(id: _currentSession, name: sessionName)
    }

    /// The most recent error from `record`, which cannot throw.
    public var lastError: Error? { withLock { _lastError } }

    public var currentSession: UUID { withLock { _currentSession } }

    /// Starts a new session; subsequent events are recorded into it.
    @discardableResult
    public func startSession(named name: String, createdAt: Date = Date()) throws -> UUID {
        let id = UUID()
        try insertSession(id: id, name: name, createdAt: createdAt)
        withLock { _currentSession = id }
        return id
    }

    // MARK: Writing

    public func record(_ event: CaptureEvent) {
        withLock {
            do {
                try insert(event, session: _currentSession)
            } catch {
                _lastError = error
            }
        }
    }

    /// Records `event` into the current session and returns it as stored, for live UIs that
    /// need the row id and derived columns straight away.
    @discardableResult
    public func append(_ event: CaptureEvent) throws -> StoredCaptureEvent {
        try withLock { try insert(event, session: _currentSession) }
    }

    @discardableResult
    private func insert(_ event: CaptureEvent, session: UUID) throws -> StoredCaptureEvent {
        let index = EventIndex(event, recordedAt: Date())
        let payload = try encoder.encode(StoredEvent(event))
        return try database.transaction {
            try database.query(
                "INSERT INTO events (session_id, kind, timestamp, host, summary, payload) VALUES (?, ?, ?, ?, ?, ?)",
                [.text(session.uuidString), .text(index.kind), .real(index.timestamp.timeIntervalSince1970),
                 .text(index.host), .text(index.summary), .blob(payload)]
            )
            let id = database.lastInsertRowID
            try database.query(
                "INSERT INTO events_fts (rowid, content) VALUES (?, ?)",
                [.integer(id), .text(index.searchText)]
            )
            return StoredCaptureEvent(id: id, sessionID: session, kind: index.kind, host: index.host, summary: index.summary,
                                      timestamp: index.timestamp, event: event)
        }
    }

    // MARK: Reading

    /// Every session, newest first, with its event counts.
    public func sessions() throws -> [CaptureSession] {
        try withLock {
            var kinds: [String: [String: Int]] = [:]
            for row in try database.query("SELECT session_id, kind, COUNT(*) FROM events GROUP BY session_id, kind") {
                guard let session = row[0].string, let kind = row[1].string else { continue }
                kinds[session, default: [:]][kind] = Int(row[2].int ?? 0)
            }
            return try database.query("""
                SELECT s.id, s.name, s.created_at, COUNT(e.id), MAX(e.timestamp)
                FROM sessions s LEFT JOIN events e ON e.session_id = s.id
                GROUP BY s.id ORDER BY s.created_at DESC, s.rowid DESC
                """).compactMap { row in
                guard let key = row[0].string, let id = UUID(uuidString: key) else { return nil }
                return CaptureSession(
                    id: id,
                    name: row[1].string ?? "",
                    createdAt: Date(timeIntervalSince1970: row[2].double ?? 0),
                    eventCount: Int(row[3].int ?? 0),
                    lastEventAt: row[4].double.map(Date.init(timeIntervalSince1970:)),
                    kindCounts: kinds[key] ?? [:]
                )
            }
        }
    }

    /// Every event of a session in capture order, read in pages.
    public func allEvents(in session: UUID) throws -> [StoredCaptureEvent] {
        var result: [StoredCaptureEvent] = []
        let page = 2000
        while true {
            let batch = try events(in: session, limit: page, offset: result.count)
            result += batch
            if batch.count < page { return result }
        }
    }

    /// Removes earlier sessions that never recorded anything (every launch starts one). Returns how many.
    @discardableResult
    public func deleteEmptySessions() throws -> Int {
        try withLock {
            let rows = try database.query(
                "SELECT id FROM sessions WHERE id != ? AND NOT EXISTS (SELECT 1 FROM events WHERE session_id = sessions.id)",
                [.text(_currentSession.uuidString)]
            )
            try database.query(
                "DELETE FROM sessions WHERE id != ? AND NOT EXISTS (SELECT 1 FROM events WHERE session_id = sessions.id)",
                [.text(_currentSession.uuidString)]
            )
            return rows.count
        }
    }

    /// Events of a session in capture order, optionally limited to some kinds
    /// (`http`, `mqtt`, `websocket`, `tunnel`, `tls`).
    public func events(in session: UUID, kinds: Set<String>? = nil, limit: Int = 1000, offset: Int = 0) throws -> [StoredCaptureEvent] {
        let all = try withLock {
            try database.query(
                "SELECT id, session_id, kind, host, summary, payload, timestamp FROM events WHERE session_id = ? ORDER BY id LIMIT ? OFFSET ?",
                [.text(session.uuidString), .integer(Int64(limit)), .integer(Int64(offset))]
            )
        }
        return try all.map(decodeRow).filter { kinds?.contains($0.kind) ?? true }
    }

    /// Full-text search over URLs, headers, text bodies, MQTT topics, client IDs and payloads.
    /// Every word must match (prefix matching), e.g. `sensors temp` or `api.example 500`.
    public func search(_ text: String, in session: UUID? = nil, limit: Int = 500) throws -> [StoredCaptureEvent] {
        let match = Self.ftsQuery(text)
        guard !match.isEmpty else { return [] }
        var sql = """
            SELECT e.id, e.session_id, e.kind, e.host, e.summary, e.payload, e.timestamp
            FROM events_fts f JOIN events e ON e.id = f.rowid
            WHERE events_fts MATCH ?
            """
        var bindings: [SQLiteValue] = [.text(match)]
        if let session {
            sql += " AND e.session_id = ?"
            bindings.append(.text(session.uuidString))
        }
        sql += " ORDER BY e.id LIMIT ?"
        bindings.append(.integer(Int64(limit)))
        let rows = try withLock { try database.query(sql, bindings) }
        return try rows.map(decodeRow)
    }

    public func renameSession(_ id: UUID, to name: String) throws {
        try withLock { try database.query("UPDATE sessions SET name = ? WHERE id = ?", [.text(name), .text(id.uuidString)]) }
    }

    /// Deletes a session and its events. The current session cannot be deleted.
    public func deleteSession(_ id: UUID) throws {
        try withLock {
            guard id != _currentSession else { throw CaptureStoreError.cannotDeleteCurrentSession }
            try database.transaction {
                try database.query(
                    "DELETE FROM events_fts WHERE rowid IN (SELECT id FROM events WHERE session_id = ?)",
                    [.text(id.uuidString)]
                )
                try database.query("DELETE FROM events WHERE session_id = ?", [.text(id.uuidString)])
                try database.query("DELETE FROM sessions WHERE id = ?", [.text(id.uuidString)])
            }
        }
    }

    /// Records into an earlier session again, as if it never ended. The session that was current is
    /// removed when it never recorded anything (every launch starts one).
    public func resumeSession(_ id: UUID) throws {
        try withLock {
            guard id != _currentSession else { return }
            let exists = try database.query("SELECT 1 FROM sessions WHERE id = ?", [.text(id.uuidString)])
            guard !exists.isEmpty else { throw CaptureStoreError.unknownSession }
            let previous = _currentSession
            _currentSession = id
            try database.query(
                "DELETE FROM sessions WHERE id = ? AND NOT EXISTS (SELECT 1 FROM events WHERE session_id = sessions.id)",
                [.text(previous.uuidString)]
            )
        }
    }

    // MARK: Helpers

    private func decodeRow(_ row: [SQLiteValue]) throws -> StoredCaptureEvent {
        let stored = try decoder.decode(StoredEvent.self, from: row[5].data ?? Data())
        return StoredCaptureEvent(
            id: row[0].int ?? 0,
            sessionID: row[1].string.flatMap(UUID.init(uuidString:)) ?? UUID(),
            kind: row[2].string ?? "",
            host: row[3].string ?? "",
            summary: row[4].string ?? "",
            timestamp: Date(timeIntervalSince1970: row[6].double ?? 0),
            event: try stored.captureEvent()
        )
    }

    private func insertSession(id: UUID, name: String, createdAt: Date = Date()) throws {
        try withLock {
            try database.query(
                "INSERT INTO sessions (id, name, created_at) VALUES (?, ?, ?)",
                [.text(id.uuidString), .text(name), .real(createdAt.timeIntervalSince1970)]
            )
        }
    }

    @discardableResult
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Turns free text into an FTS5 query: each word quoted (so punctuation is literal) and prefix-matched.
    static func ftsQuery(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
            .joined(separator: " ")
    }

    static func migrate(_ database: SQLiteDatabase) throws {
        let version = try database.query("PRAGMA user_version").first?.first?.int ?? 0
        if version < 1 {
            try database.execute("""
                CREATE TABLE sessions (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE TABLE events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    timestamp REAL NOT NULL,
                    host TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX events_session ON events(session_id, id);
                CREATE VIRTUAL TABLE events_fts USING fts5(content, tokenize = 'unicode61');
                PRAGMA user_version = 1;
                """)
        }
    }
}

public enum CaptureStoreError: Error, Equatable {
    case cannotDeleteCurrentSession
    case unknownSession
}
