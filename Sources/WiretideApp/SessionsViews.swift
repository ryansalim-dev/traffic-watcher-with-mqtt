#if os(macOS)
import AppCore
import AppKit
import CaptureStore
import SwiftUI
import UniformTypeIdentifiers

/// The Saved Sessions window: every capture session on this Mac, newest first. A session can be opened
/// in the main timeline (live capture keeps recording behind it), renamed, exported or deleted.
struct SessionsWindow: View {
    static let id = "sessions"
    @Bindable var model: CaptureViewModel
    let license: LicenseManager
    @State private var selection: UUID?
    @State private var limitPrompt: SessionLimitPrompt?

    var body: some View {
        HStack(spacing: 0) {
            SessionsList(model: model, selection: $selection, limitPrompt: $limitPrompt)
                .frame(width: 300)
                .background(Theme.sidebar)
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }
            VStack(spacing: 0) {
                if let limit = license.savedSessionLimit {
                    ProNotice(feature: "Keeping every session", detail: FreeSessions.notice(limit: limit, saved: model.savedSessions.count))
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                }
                if let session = selectedSession {
                    SessionDetail(model: model, session: session)
                        .id(session.id)
                } else {
                    ContentUnavailableView("No session selected", systemImage: "clock.arrow.circlepath",
                                           description: Text("Pick a session on the left to open, rename or export it."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.panel)
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 520, idealHeight: 600)
        .background(GraphiteWindow())
        .tint(Theme.accent)
        .sheet(item: $limitPrompt) { prompt in
            SessionLimitSheet(model: model, prompt: prompt) {
                limitPrompt = nil
                selection = model.sessions.first?.id
            }
        }
        .onAppear {
            model.reloadSessions()
            if selection == nil { selection = model.viewedSession?.id ?? model.sessions.first(where: { !model.isLive($0) })?.id ?? model.sessions.first?.id }
        }
        .onChange(of: model.sessions) {
            if let selection, !model.sessions.contains(where: { $0.id == selection }) {
                self.selection = model.sessions.first?.id
            }
        }
    }

    private var selectedSession: CaptureSession? {
        guard let selection else { return nil }
        return model.sessions.first { $0.id == selection }
    }
}

struct SessionsList: View {
    @Bindable var model: CaptureViewModel
    @Binding var selection: UUID?
    @Binding var limitPrompt: SessionLimitPrompt?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved Sessions").font(.system(size: 14, weight: .semibold))
                Text(summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.title) { group in
                        CapsLabel(group.title)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                        ForEach(group.sessions) { session in
                            SessionRow(session: session, isLive: model.isLive(session),
                                       isShown: model.viewedSession?.id == session.id,
                                       isSelected: selection == session.id) {
                                selection = session.id
                            } open: {
                                model.openSession(session.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }

            HStack(spacing: 6) {
                Button {
                    let name = SessionNames.now()
                    if let prompt = model.sessionLimitPrompt(forNewSessionNamed: name) {
                        limitPrompt = prompt
                    } else {
                        model.newSession(named: name)
                        selection = model.sessions.first?.id
                    }
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Start recording into a new session (⇧⌘N)")
                Spacer()
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }

    private var summary: String {
        let saved = model.sessions.count
        let events = model.sessions.reduce(0) { $0 + $1.eventCount }
        return "\(saved) session\(saved == 1 ? "" : "s") · \(events.formatted()) events"
    }

    /// Recording now, then Today, Yesterday, This Week and Earlier.
    private var groups: [(title: String, sessions: [CaptureSession])] {
        let calendar = Calendar.current
        let now = Date()
        var live: [CaptureSession] = [], today: [CaptureSession] = [], yesterday: [CaptureSession] = []
        var week: [CaptureSession] = [], earlier: [CaptureSession] = []
        for session in model.sessions {
            if model.isLive(session) { live.append(session) }
            else if calendar.isDateInToday(session.createdAt) { today.append(session) }
            else if calendar.isDateInYesterday(session.createdAt) { yesterday.append(session) }
            else if let days = calendar.dateComponents([.day], from: session.createdAt, to: now).day, days < 7 { week.append(session) }
            else { earlier.append(session) }
        }
        return [("Recording now", live), ("Today", today), ("Yesterday", yesterday), ("This week", week), ("Earlier", earlier)]
            .filter { !$0.1.isEmpty }
            .map { (title: $0.0, sessions: $0.1) }
    }
}

struct SessionRow: View {
    let session: CaptureSession
    let isLive: Bool
    let isShown: Bool
    let isSelected: Bool
    let select: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isLive { StatusDot(color: Theme.failure, size: 6) }
                    Text(session.name.isEmpty ? "Untitled session" : session.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(SessionFormat.line(session))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isShown {
                Image(systemName: "eye.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.accent)
                    .help("Shown in the timeline")
            }
            SessionKindBar(counts: session.kindCounts, total: session.eventCount)
                .frame(width: 44, height: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Theme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent.opacity(0.35), lineWidth: 0.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: select)
    }
}

/// The share of HTTP, MQTT and WebSocket events in a session, as one thin stacked bar.
struct SessionKindBar: View {
    let counts: [String: Int]
    let total: Int

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(SessionFormat.kinds, id: \.key) { kind in
                    let count = counts[kind.key] ?? 0
                    if count > 0 {
                        Rectangle().fill(kind.color)
                            .frame(width: max(2, geometry.size.width * CGFloat(count) / CGFloat(max(total, 1))))
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.fill)
            .clipShape(Capsule())
        }
        .accessibilityHidden(true)
    }
}

struct SessionDetail: View {
    @Bindable var model: CaptureViewModel
    let session: CaptureSession
    @State private var name = ""
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool

    private var isLive: Bool { model.isLive(session) }
    private var isShown: Bool { isLive ? model.viewedSession == nil : model.viewedSession?.id == session.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if isLive {
                            Text("RECORDING INTO THIS SESSION")
                                .font(Theme.label)
                                .kerning(0.6)
                                .foregroundStyle(Theme.failure)
                        } else if isShown {
                            Text("SHOWN IN THE TIMELINE")
                                .font(Theme.label)
                                .kerning(0.6)
                                .foregroundStyle(Theme.accent)
                        } else {
                            CapsLabel("Saved session")
                        }
                    }
                    TextField("Session name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .semibold))
                        .focused($nameFocused)
                        .onSubmit(commitName)
                        .onChange(of: nameFocused) { if !nameFocused { commitName() } }
                    Text(SessionFormat.recorded(session))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                HStack(spacing: 10) {
                    ForEach(SessionFormat.kinds, id: \.key) { kind in
                        SessionStat(title: kind.title, value: session.kindCounts[kind.key] ?? 0, color: kind.color)
                    }
                    SessionStat(title: "Other", value: SessionFormat.other(session), color: Theme.neutral)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        if isShown {
                            Button {
                                model.returnToLive()
                            } label: {
                                Label(isLive ? "In the timeline now" : "Back to Live Capture", systemImage: isLive ? "checkmark" : "dot.radiowaves.left.and.right")
                            }
                            .disabled(isLive)
                        } else {
                            Button {
                                model.openSession(session.id)
                            } label: {
                                Label(isLive ? "Back to Live Capture" : "Open in Timeline", systemImage: "rectangle.stack")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(session.eventCount == 0 && !isLive)
                        }
                        SessionExportMenu(model: model, session: session)
                        .fixedSize()
                        Spacer()
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Delete…", systemImage: "trash")
                        }
                        .disabled(isLive)
                        .help(isLive ? "Start a new session to delete this one" : "Delete this session and its events")
                    }
                    .controlSize(.large)
                    Text(hint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { name = session.name }
        .confirmationDialog("Delete “\(session.name)”?", isPresented: $confirmingDelete) {
            Button("Delete Session", role: .destructive) { model.deleteSession(session.id) }
        } message: {
            Text("Its \(session.eventCount.formatted()) events are removed from this Mac. This can't be undone.")
        }
    }

    private var hint: String {
        if isLive { return "New traffic is recorded here. Start a new session from the list or with ⇧⌘N." }
        return "Opening a session shows it in the timeline. Recording carries on in the live session behind it; use Back to Live (⇧⌘L) to return."
    }

    private func commitName() {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = session.name
        } else if name != session.name {
            model.renameSession(session.id, to: name)
        }
    }
}

struct SessionStat: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Text(value.formatted())
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(value == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
    }
}

/// A saved session in the main window's sidebar.
struct SidebarSessionRow: View {
    let session: CaptureSession
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: isOn ? "eye.fill" : "clock.arrow.circlepath")
                    .font(.system(size: 11.5))
                    .foregroundStyle(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 18)
                Text(session.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                    .fontWeight(isOn ? .semibold : .regular)
                Spacer(minLength: 4)
                Text(session.eventCount.formatted())
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Back to live capture" : "Show this session in the timeline")
    }
}

/// Above the timeline while a saved session is shown instead of live capture.
struct SavedSessionBanner: View {
    let session: CaptureSession
    let backToLive: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.accent)
            Text("Saved session").font(.system(size: 12, weight: .semibold))
            Text(session.name).font(.system(size: 12)).lineLimit(1)
            Text(SessionFormat.line(session))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: backToLive) {
                Label("Back to Live", systemImage: "dot.radiowaves.left.and.right")
            }
            .controlSize(.small)
            .help("Show live capture again (⇧⌘L). Recording never stopped.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        // Opaque, so timeline rows scrolling under the inset don't show through.
        .background(Theme.accent.opacity(0.12))
        .background(Theme.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

enum SessionFormat {
    static let kinds: [(key: String, title: String, color: Color)] = [
        ("http", "HTTP", Theme.accent), ("mqtt", "MQTT", Theme.mqtt), ("websocket", "WebSocket", Theme.webSocket),
    ]

    static func other(_ session: CaptureSession) -> Int {
        session.eventCount - kinds.reduce(0) { $0 + (session.kindCounts[$1.key] ?? 0) }
    }

    /// "14:05 · 12 min · 1,204 events"
    static func line(_ session: CaptureSession) -> String {
        // The list already groups by day, so recent sessions show only their time.
        let calendar = Calendar.current
        let recent = calendar.isDateInToday(session.createdAt) || calendar.isDateInYesterday(session.createdAt)
        var parts = [recent ? session.createdAt.formatted(date: .omitted, time: .shortened)
                            : session.createdAt.formatted(.dateTime.month(.abbreviated).day())]
        if let length = length(session) { parts.append(length) }
        parts.append("\(session.eventCount.formatted()) event\(session.eventCount == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    /// "Recorded Nov 2, 2026, 14:05 to 14:17 (12 min)"
    static func recorded(_ session: CaptureSession) -> String {
        let start = session.createdAt.formatted(date: .abbreviated, time: .shortened)
        guard let end = session.lastEventAt, let length = length(session) else {
            return "Started \(start) · nothing recorded yet"
        }
        let sameDay = Calendar.current.isDate(end, inSameDayAs: session.createdAt)
        return "Recorded \(start) to \(end.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened)) (\(length))"
    }

    static func length(_ session: CaptureSession) -> String? {
        guard let end = session.lastEventAt else { return nil }
        let seconds = max(0, end.timeIntervalSince(session.createdAt))
        if seconds < 60 { return "<1 min" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// Export as HAR (HTTP) or JSON Lines (MQTT). Free on every tier.
struct SessionExportMenu: View {
    let model: CaptureViewModel
    let session: CaptureSession
    var title = "Export"

    var body: some View {
        Menu {
            Button("HTTP as HAR…") {
                SessionExport.save(name: "\(fileName).har", type: .json) { try model.exportHAR(session: session.id) }
            }
            .disabled((session.kindCounts["http"] ?? 0) == 0)
            Button("MQTT as JSON Lines…") {
                SessionExport.save(name: "\(fileName).jsonl", type: .plainText) { try model.exportMQTT(session: session.id) }
            }
            .disabled((session.kindCounts["mqtt"] ?? 0) == 0)
        } label: {
            Label(title, systemImage: "square.and.arrow.up")
        }
        .fixedSize()
    }

    private var fileName: String {
        let cleaned = session.name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return cleaned.isEmpty ? "session" : cleaned
    }
}

enum SessionExport {
    @MainActor
    static func save(name: String, type: UTType, data: () throws -> Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data().write(to: url)
        } catch {
            _ = NSAlert(error: error).runModal()
        }
    }
}

enum FreeSessions {
    static func count(_ n: Int) -> String {
        n == 1 ? "one saved session" : "\(n) saved sessions"
    }

    /// The line under "Keeping every session is part of Wiretide Pro" in the Saved Sessions window.
    static func notice(limit: Int, saved: Int) -> String {
        if saved > limit {
            return "Free keeps \(count(limit)) next to the one recording now. Your \(saved) earlier sessions stay until you start a new one."
        }
        return "Free keeps \(count(limit)) next to the one recording now. Export works on every session."
    }
}

/// New Session on the free tier when the saved sessions are full: explains Pro, offers to export
/// what would be replaced, and replaces it only when asked.
struct SessionLimitSheet: View {
    let model: CaptureViewModel
    let prompt: SessionLimitPrompt
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 36, height: 36)
                        .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wiretide Free keeps \(FreeSessions.count(prompt.limit))")
                            .font(.system(size: 15, weight: .semibold))
                        Text(explanation)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    CapsLabel(prompt.replacing.count == 1 ? "Will be replaced" : "Will be replaced (\(prompt.replacing.count))")
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(prompt.replacing) { session in
                                ReplacedSessionRow(model: model, session: session)
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Image(systemName: "seal.fill").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wiretide Pro keeps every session").font(.system(size: 12.5, weight: .semibold))
                        Text("A one-time purchase that also adds breakpoints, map and rewrite, MQTT publish and replay, and scripting.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    SettingsLink { Text("Upgrade…") }
                }
                .padding(12)
                .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.accent.opacity(0.25), lineWidth: 0.5))
            }
            .padding(20)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    model.replaceAndStartNewSession(prompt)
                    dismiss()
                } label: {
                    Text(prompt.replacing.count == 1 ? "Replace and Start New Session" : "Replace \(prompt.replacing.count) and Start New Session")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.failure)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .frame(width: 520)
        .background(Theme.panel)
        .tint(Theme.accent)
    }

    private var explanation: String {
        let saving = "“\(prompt.saving.name)” becomes your saved session"
        let replaced = prompt.replacing.count == 1 ? "the one below is deleted" : "the \(prompt.replacing.count) below are deleted"
        return "Starting a new session keeps what you just recorded: \(saving) and \(replaced). Export anything you want to keep first; export is free."
    }
}

struct ReplacedSessionRow: View {
    let model: CaptureViewModel
    let session: CaptureSession

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name.isEmpty ? "Untitled session" : session.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(SessionFormat.line(session))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            SessionKindBar(counts: session.kindCounts, total: session.eventCount)
                .frame(width: 44, height: 4)
            SessionExportMenu(model: model, session: session, title: "Export…")
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
    }
}

enum SessionNames {
    /// The name a new session gets, like the one started at launch.
    static func now() -> String {
        Date().formatted(date: .abbreviated, time: .shortened)
    }
}
#endif
