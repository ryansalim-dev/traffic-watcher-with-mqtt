#if os(macOS)
import AppCore
import AppKit
import MQTTCore
import ProxyCore
import SwiftUI

extension Theme {
    /// The list pill for a script: what traffic it sees.
    static func pill(for script: UserScript) -> (text: String, color: Color) {
        switch (script.handlesHTTP, script.handlesMQTT) {
        case (true, true): ("HTTP+MQ", put)
        case (true, false): ("HTTP", get)
        case (false, true): ("MQTT", mqtt)
        case (false, false): ("JS", neutral)
        }
    }

    static func color(for level: ScriptLogEntry.Level) -> Color {
        switch level {
        case .log: .primary
        case .info: accent
        case .warn: warning
        case .error: failure
        }
    }
}

/// Toolbar button for scripts: opens the scripts window and shows how many scripts are on.
struct ScriptsToolbarButton: View {
    let center: ScriptCenter

    var body: some View {
        Button {
            center.isPresented = true
        } label: {
            Label {
                Text("Scripts")
            } icon: {
                Image(systemName: "curlybraces")
                    .overlay(alignment: .topTrailing) {
                        if center.isActive && center.enabledCount > 0 {
                            Text(center.enabledCount.formatted())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 3)
                                .frame(minWidth: 14, minHeight: 14)
                                .background(Theme.accent, in: Capsule())
                                .offset(x: 8, y: -7)
                        }
                    }
            }
        }
        .foregroundStyle(center.isActive && center.enabledCount > 0 ? Theme.accent : Color.secondary)
        .help(help)
    }

    private var help: String {
        if !center.isAllowed { return "Scripting is part of Wiretide Pro (⇧⌘J)" }
        if !center.isEnabled { return "Scripts are off (⇧⌘J)" }
        let count = center.enabledCount
        return "\(count) script\(count == 1 ? "" : "s") on (⇧⌘J)"
    }
}

// MARK: Window

/// The Scripts window: scripts on the left; the selected script's match settings, code and console on the right.
struct ScriptsWindow: View {
    static let id = "scripts"
    @Bindable var model: CaptureViewModel

    private var center: ScriptCenter { model.scripts }

    var body: some View {
        HStack(spacing: 0) {
            ScriptsList(center: center)
                .frame(width: 280)
                .background(Theme.sidebar)
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }
            VStack(spacing: 0) {
                if !center.isAllowed {
                    ProNotice(feature: "Scripting",
                              detail: "Your scripts are kept, and you can try them on captured traffic, but they only change live traffic with Pro.")
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                }
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .background(Theme.panel)
        }
        .frame(minWidth: 940, idealWidth: 1040, minHeight: 640, idealHeight: 720)
        .background(GraphiteWindow())
        .tint(Theme.accent)
    }

    @ViewBuilder private var editor: some View {
        if let id = center.selection, let binding = binding(id) {
            ScriptEditor(center: center, script: binding, rows: model.rows)
                .id(id)
        } else {
            ScriptsEmptyState(center: center)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            StatusDot(color: center.isActive ? Theme.success : Theme.neutral, halo: center.isActive)
            Text(footerText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let selection = center.selection {
                Button("Duplicate") { center.duplicate(selection) }
                    .buttonStyle(ChipButtonStyle())
                Button("Delete", role: .destructive) { center.remove(selection) }
                    .buttonStyle(ChipButtonStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var footerText: String {
        if !LiveScripts.isSupported { return "Scripts need JavaScriptCore, which this system doesn't have" }
        if !center.isAllowed { return "Scripts are saved and start running when Pro is active" }
        if !center.isEnabled { return "Scripts are off; traffic passes untouched" }
        return "Edits apply to the next request · scripts restart from the top when edited"
    }

    private func binding(_ id: UUID) -> Binding<UserScript>? {
        guard center.scripts.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { center.scripts.first { $0.id == id } ?? UserScript() },
            set: { updated in
                if let index = center.scripts.firstIndex(where: { $0.id == id }) { center.scripts[index] = updated }
            }
        )
    }
}

/// The scripts column: master switch, the scripts, and the add menu with templates.
struct ScriptsList: View {
    @Bindable var center: ScriptCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scripts").font(.system(size: 14, weight: .semibold))
                    Text("\(center.enabledCount) of \(center.scripts.count) scripts on")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Toggle("Scripts", isOn: $center.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Turn every script on or off at once")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    CapsLabel("Run in order")
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    ForEach($center.scripts) { $script in
                        let pill = Theme.pill(for: script)
                        RuleRow(isOn: $script.isEnabled, pill: pill.text, color: pill.color,
                                title: script.displayName, detail: detail(script),
                                isSelected: center.selection == script.id) {
                            center.selection = script.id
                        }
                    }
                    if center.scripts.isEmpty {
                        Text("No scripts yet")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }

            HStack(spacing: 6) {
                Menu {
                    ForEach(ScriptTemplate.allCases) { template in
                        Button(template.title) { center.addScript(template) }
                    }
                } label: {
                    Label("New Script", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Start a script from a template")
                Spacer()
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }

    private func detail(_ script: UserScript) -> String {
        var parts: [String] = []
        if script.handlesHTTP { parts.append((script.method.map { "\($0) " } ?? "") + script.urlPattern) }
        if script.handlesMQTT { parts.append(script.topicFilter) }
        return parts.isEmpty ? "Matches nothing yet" : parts.joined(separator: " · ")
    }
}

/// Shown when no script is selected: what scripts do, and templates to start from.
struct ScriptsEmptyState: View {
    let center: ScriptCenter

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "curlybraces")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Change traffic with code")
                    .font(.system(size: 15, weight: .semibold))
                Text("Scripts are JavaScript functions Wiretide calls for each matching request, response and MQTT message. Right-click anything in the timeline to start from it.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                card(.addHeader, pill: "REQUEST", color: Theme.get, symbol: "arrow.up.right")
                card(.editJSONResponse, pill: "RESPONSE", color: Theme.post, symbol: "arrow.down.left")
                card(.mockResponse, pill: "RESPOND", color: Theme.put, symbol: "text.bubble")
                card(.mqttPayload, pill: "PUBLISH", color: Theme.mqtt, symbol: "antenna.radiowaves.left.and.right")
            }
            .frame(maxWidth: 580)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ template: ScriptTemplate, pill: String, color: Color, symbol: String) -> some View {
        RuleKindCard(title: template.title, pill: pill, color: color, symbol: symbol, text: template.summary) {
            center.addScript(template)
        }
    }
}

// MARK: Editor

/// Edits one script: name and what it matches, then the code, with the console below.
struct ScriptEditor: View {
    let center: ScriptCenter
    @Binding var script: UserScript
    let rows: [TrafficRow]
    @State private var showsReference = false

    var body: some View {
        let problem = ScriptSyntax.check(script.source)
        let hooks = script.definedHooks
        VStack(alignment: .leading, spacing: 0) {
            matchSettings
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            HStack(spacing: 8) {
                ForEach(ScriptHook.allCases, id: \.self) { hook in
                    HookChip(hook: hook, isDefined: hooks.contains(hook), isMatched: isMatched(hook))
                }
                Spacer(minLength: 8)
                SyntaxStatus(problem: problem)
                Button {
                    showsReference.toggle()
                } label: {
                    Image(systemName: "book")
                }
                .buttonStyle(MiniButtonStyle(selected: showsReference))
                .help("What scripts can use")
                .popover(isPresented: $showsReference, arrowEdge: .bottom) { ScriptReference() }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            CodeEditor(text: $script.source, highlightJavaScript: true, fontSize: 12.5)
                .frame(maxHeight: .infinity)

            ScriptConsole(center: center, script: script, latestMatch: ScriptCenter.latestMatch(for: script, in: rows),
                          canRun: problem == nil && !hooks.isEmpty)
                .frame(height: 200)
        }
    }

    private func isMatched(_ hook: ScriptHook) -> Bool {
        hook == .publish ? script.handlesMQTT : script.handlesHTTP
    }

    private var matchSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Name", text: $script.name, prompt: Text(script.displayName))
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
            HStack(alignment: .bottom, spacing: 16) {
                HStack(alignment: .bottom, spacing: 8) {
                    FieldGroup(label: "Method") {
                        Picker("Method", selection: Binding(get: { script.method ?? "" }, set: { script.method = $0.isEmpty ? nil : $0 })) {
                            Text("Any").tag("")
                            ForEach(HTTPRuleEditor.methods, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 84)
                    }
                    FieldGroup(label: "HTTP · URL pattern") {
                        BoxedTextField(title: "URL pattern", text: $script.urlPattern, prompt: "api.example.com/*", monospaced: true)
                    }
                }
                .frame(maxWidth: .infinity)
                HStack(alignment: .bottom, spacing: 8) {
                    FieldGroup(label: "MQTT · topic filter") {
                        BoxedTextField(title: "Topic filter", text: $script.topicFilter, prompt: "home/#", monospaced: true)
                    }
                    FieldGroup(label: "Direction") {
                        Picker("Direction", selection: $script.direction) {
                            ForEach(MQTTRule.Direction.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 136)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            ScriptMatchSummary(script: script, rows: rows)
        }
    }
}

/// "Matches 12 requests · 3 topics in this session" under the match fields.
struct ScriptMatchSummary: View {
    let script: UserScript
    let rows: [TrafficRow]

    var body: some View {
        let requests = script.handlesHTTP ? RewriteCenter.matchingURLs(HTTPRule(pattern: script.urlPattern, method: script.method, kind: .rewrite), in: rows) : []
        let topics = script.handlesMQTT
            ? RewriteCenter.matchingTopics(MQTTRule(topicFilter: script.topicFilter, direction: script.direction), in: rows) : []
        return HStack(spacing: 7) {
            StatusDot(color: requests.isEmpty && topics.isEmpty ? Theme.neutral : Theme.success)
            if !script.handlesHTTP && !script.handlesMQTT {
                Text("Enter a URL pattern, a topic filter or both; empty means that kind of traffic is skipped")
                    .foregroundStyle(.secondary)
            } else if requests.isEmpty && topics.isEmpty {
                Text("Nothing in this session matches yet").foregroundStyle(.secondary)
            } else {
                Text(summary(requests: requests.count, topics: topics.count))
                if let example = requests.first ?? topics.first {
                    Text(example)
                        .font(Theme.monoSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }

    private func summary(requests: Int, topics: Int) -> String {
        var parts: [String] = []
        if script.handlesHTTP { parts.append("\(requests >= 200 ? "200+" : requests.formatted()) request\(requests == 1 ? "" : "s")") }
        if script.handlesMQTT { parts.append("\(topics.formatted()) topic\(topics == 1 ? "" : "s")") }
        return "Matches " + parts.joined(separator: " and ") + " in this session"
    }
}

/// `onRequest` and friends: teal when the script defines the hook and matches its traffic.
struct HookChip: View {
    let hook: ScriptHook
    let isDefined: Bool
    let isMatched: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isDefined ? (isMatched ? "checkmark.circle.fill" : "exclamationmark.circle") : "circle.dashed")
                .font(.system(size: 10.5))
            Text(hook.functionName)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .foregroundStyle(color)
        .background(isDefined ? color.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(isDefined ? Color.clear : Theme.hairline)
        }
        .help(help)
    }

    private var color: Color {
        guard isDefined else { return Theme.neutral }
        return isMatched ? Theme.accent : Theme.warning
    }

    private var help: String {
        let what = hook == .publish ? "a topic filter" : "a URL pattern"
        if !isDefined { return "\(hook.functionName) isn't defined; define it to handle \(hook == .publish ? "MQTT messages" : hook == .request ? "requests" : "responses")" }
        if !isMatched { return "\(hook.functionName) is defined but never runs: enter \(what)" }
        return "\(hook.functionName) runs for matching \(hook == .publish ? "messages" : hook == .request ? "requests" : "responses")"
    }
}

/// Syntax check result next to the hook chips.
struct SyntaxStatus: View {
    let problem: ScriptSyntax.Problem?

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: problem == nil ? Theme.success : Theme.failure)
            if let problem {
                Text(problem.line.map { "Line \($0): \(problem.message)" } ?? problem.message)
                    .foregroundStyle(Theme.failure)
            } else {
                Text("No syntax errors").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

// MARK: Console

/// What the scripts logged and the errors they hit, with a button to try the script on captured traffic.
struct ScriptConsole: View {
    let center: ScriptCenter
    let script: UserScript
    let latestMatch: TrafficRow?
    let canRun: Bool
    @State private var showsAll = false

    var body: some View {
        let entries = center.log.filter { showsAll || $0.scriptID == script.id || $0.scriptID == nil }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                CapsLabel("Console")
                Text(entries.count.formatted())
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                PillSegments(options: [(false, "This script"), (true, "All")], selection: $showsAll)
                    .frame(width: 150)
                Spacer()
                Button("Clear") { center.clearLog() }
                    .buttonStyle(MiniButtonStyle())
                    .disabled(center.log.isEmpty)
                Button {
                    guard let latestMatch else { return }
                    Task { await center.test(script, on: latestMatch) }
                } label: {
                    Label("Run on Latest Match", systemImage: "play.fill")
                }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .disabled(latestMatch == nil || !canRun || center.isTesting)
                .help(runHelp)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Theme.bar)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            if entries.isEmpty {
                Text("console.log output and errors show up here. Run the script on the latest matching request or message to try it without touching live traffic.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { entry in
                                ConsoleLine(entry: entry, showsScript: showsAll).id(entry.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onAppear { proxy.scrollTo(entries.last?.id, anchor: .bottom) }
                    .onChange(of: entries.last?.id) { proxy.scrollTo(entries.last?.id, anchor: .bottom) }
                }
            }
        }
        .background(Theme.canvas)
    }

    private var runHelp: String {
        if !canRun { return "Fix the script first: it needs a hook and no syntax errors" }
        guard let latestMatch else { return "Nothing in this session matches this script yet" }
        return "Runs the script on \(latestMatch.summary) and shows what it changed; live traffic isn't touched"
    }
}

struct ConsoleLine: View {
    let entry: ScriptLogEntry
    let showsScript: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.color(for: entry.level))
                .frame(width: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .foregroundStyle(entry.level == .log ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.color(for: entry.level)))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(showsScript ? "\(entry.scriptName) · \(entry.context)" : entry.context)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 18)
        .padding(.vertical, 5)
        .background(entry.level == .error ? Theme.failure.opacity(0.07) : Color.clear)
    }

    private var message: String {
        guard let line = entry.line else { return entry.message }
        return "\(entry.message) (line \(line))"
    }

    private var symbol: String {
        switch entry.level {
        case .log: "chevron.right"
        case .info: "checkmark"
        case .warn: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

// MARK: Reference

/// The popover behind the book button: the objects scripts get and the helpers they can call.
struct ScriptReference: View {
    private let sections: [(title: String, items: [(String, String)])] = [
        ("Hooks", [
            ("onRequest(request)", "Before the request goes out. Return it, or return respond(…) to answer locally."),
            ("onResponse(request, response)", "Before the response reaches the app."),
            ("onPublish(message)", "For each PUBLISH through a forwarder, in either direction."),
        ]),
        ("request", [
            ("method, url", "Change either to send the request elsewhere."),
            ("host, path, query", "Read-only parts of the URL; edit query to change parameters."),
            ("headers", "Case-insensitive: headers[\"content-type\"]. Delete to remove."),
            ("body, json, bodyBase64", "Text (null if binary), parsed JSON, raw bytes. Edit any one."),
        ]),
        ("response", [
            ("status, headers", "Status code and headers, as above."),
            ("body, json, bodyBase64", "As for requests."),
        ]),
        ("message", [
            ("topic, retain", "Editable. QoS and packet IDs are kept so acknowledgements match."),
            ("payload, json, payloadBase64", "Text, parsed JSON, raw bytes."),
            ("qos, direction, broker, clientId", "Read-only."),
        ]),
        ("Helpers", [
            ("respond(status, body, headers)", "Or respond({ status, json, headers }). Answers without the server."),
            ("console.log / warn / error", "Writes to the console below."),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        CapsLabel(section.title)
                        ForEach(section.items, id: \.0) { item in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.0).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.accent)
                                Text(item.1).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Text("Scripts run synchronously and are stopped after \(JavaScriptEngine.seconds(JavaScriptEngine.defaultTimeLimit)). Top-level variables keep their values until the script is edited.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(width: 360, height: 440)
    }
}
#endif
