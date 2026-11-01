import CSQLite
import Foundation

public struct SQLiteError: Error, CustomStringConvertible, Equatable {
    public var code: Int32
    public var message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// SQLITE_TRANSIENT: tells SQLite to copy bound buffers before the call returns.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal single-connection SQLite wrapper. Not thread-safe; `CaptureStore` serializes access.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let error = SQLiteError(code: result, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
            sqlite3_close(handle)
            throw error
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &message)
        if result != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw SQLiteError(code: result, message: text)
        }
    }

    /// Runs `sql` with `bindings` and returns every row. Statements are cached by SQL text.
    @discardableResult
    func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (offset, value) in bindings.enumerated() {
            try check(bind(value, to: statement, at: Int32(offset + 1)))
        }
        var rows: [[SQLiteValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else { try check(step); return rows }
            rows.append((0..<sqlite3_column_count(statement)).map { column(statement, $0) })
        }
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] { return cached }
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        statements[sql] = statement
        return statement!
    }

    private func bind(_ value: SQLiteValue, to statement: OpaquePointer, at index: Int32) -> Int32 {
        switch value {
        case .null: return sqlite3_bind_null(statement, index)
        case .integer(let v): return sqlite3_bind_int64(statement, index, v)
        case .real(let v): return sqlite3_bind_double(statement, index, v)
        case .text(let v): return sqlite3_bind_text(statement, index, v, -1, transient)
        case .blob(let v):
            return v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
        }
    }

    private func column(_ statement: OpaquePointer, _ index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default: return .null
        }
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK || result == SQLITE_ROW || result == SQLITE_DONE else {
            throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(handle)))
        }
    }
}

enum SQLiteValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var int: Int64? { if case .integer(let v) = self { v } else { nil } }
    var double: Double? {
        switch self {
        case .real(let v): v
        case .integer(let v): Double(v)
        default: nil
        }
    }
    var string: String? { if case .text(let v) = self { v } else { nil } }
    var data: Data? { if case .blob(let v) = self { v } else { nil } }
}
