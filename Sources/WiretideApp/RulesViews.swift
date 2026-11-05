#if os(macOS)
import AppCore
import AppKit
import MQTTCore
import ProxyCore
import SwiftUI

extension Theme {
    /// One color per rule kind, from the method palette so the list reads like the timeline.
    static func color(for kind: HTTPRule.Kind) -> Color {
        switch kind {
        case .mapLocal: post
        case .mapRemote: get
        case .rewrite: put
        }
    }

    static func pillText(for kind: HTTPRule.Kind) -> String {
        switch kind {
        case .mapLocal: "LOCAL"
        case .mapRemote: "REMOTE"
        case .rewrite: "REWRITE"
        }
    }
}

/// Toolbar button for map and rewrite: opens the rules window and shows how many rules are on.
struct RulesToolbarButton: View {
    let center: RewriteCenter

    var body: some View {
        Button {
            center.isPresented = true
        } label: {
            Label {
                Text("Rules")
            } icon: {
                Image(systemName: "arrow.triangle.swap")
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
        if !center.isEnabled { return "Map and rewrite are off (⇧⌘M)" }
        let count = center.enabledCount
        let free = center.isLimited ? " · Free runs 1 of each kind at a time" : ""
        return "\(count) map and rewrite rule\(count == 1 ? "" : "s") on\(free) (⇧⌘M)"
    }
}

// MARK: Window

/// The Map & Rewrite window: the rules on the left, the selected rule's editor on the right.
struct RulesWindow: View {
    static let id = "rules"
    @Bindable var model: CaptureViewModel

    private var center: RewriteCenter { model.rewrites }

    var body: some View {
        HStack(spacing: 0) {
            RulesList(center: center)
                .frame(width: 280)
                .background(Theme.sidebar)
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }
            VStack(spacing: 0) {
                if let limit = center.limit {
                    FreeLimitBanner(title: limit == 1 ? "Wiretide Free runs 1 rule of each kind at a time"
                                                      : "Wiretide Free runs \(limit) rules of each kind at a time",
                                    detail: "One Map Local, Map Remote, Rewrite and MQTT Rewrite rule can be on together. Pro runs them all.")
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                }
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .background(Theme.panel)
        }
        .frame(minWidth: 900, idealWidth: 980, minHeight: 600, idealHeight: 660)
        .background(GraphiteWindow())
        .tint(Theme.accent)
        .proLimitPrompt(Bindable(center).limitPrompt)
    }

    @ViewBuilder private var editor: some View {
        switch center.selection {
        case .http(let id):
            if let binding = httpBinding(id) {
                HTTPRuleEditor(rule: binding, rows: model.rows)
                    .id(id)
            } else {
                RulesEmptyState(center: center)
            }
        case .mqtt(let id):
            if let binding = mqttBinding(id) {
                MQTTRuleEditor(rule: binding, rows: model.rows)
                    .id(id)
            } else {
                RulesEmptyState(center: center)
            }
        case nil:
            RulesEmptyState(center: center)
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
        if !center.isEnabled { return "Map and rewrite are off; nothing is changed" }
        return "Changes apply to the next request · no restart needed"
    }

    private func httpBinding(_ id: UUID) -> Binding<HTTPRule>? {
        guard center.httpRules.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { center.httpRules.first { $0.id == id } ?? HTTPRule(pattern: "", kind: .rewrite) },
            set: { updated in
                if let index = center.httpRules.firstIndex(where: { $0.id == id }) { center.httpRules[index] = updated }
            }
        )
    }

    private func mqttBinding(_ id: UUID) -> Binding<MQTTRule>? {
        guard center.mqttRules.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { center.mqttRules.first { $0.id == id } ?? MQTTRule(topicFilter: "") },
            set: { updated in
                if let index = center.mqttRules.firstIndex(where: { $0.id == id }) { center.mqttRules[index] = updated }
            }
        )
    }
}

/// The rules column: master switch, HTTP and MQTT rules, and the add menu.
struct RulesList: View {
    @Bindable var center: RewriteCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Map & Rewrite").font(.system(size: 14, weight: .semibold))
                    Text("\(center.enabledCount) of \(center.httpRules.count + center.mqttRules.count) rules on")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Toggle("Map and rewrite", isOn: $center.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Turn every rule on or off at once")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    section("HTTP") {
                        ForEach($center.httpRules) { $rule in
                            RuleRow(isOn: $rule.isEnabled, pill: Theme.pillText(for: rule.kind), color: Theme.color(for: rule.kind),
                                    title: rule.displayName, detail: detail(rule),
                                    isHeld: center.heldRuleIDs.contains(rule.id),
                                    isSelected: center.selection == .http(rule.id)) {
                                center.selection = .http(rule.id)
                            }
                        }
                        if center.httpRules.isEmpty { emptyLine("No HTTP rules yet") }
                    }
                    section("MQTT") {
                        ForEach($center.mqttRules) { $rule in
                            RuleRow(isOn: $rule.isEnabled, pill: "MQTT", color: Theme.mqtt,
                                    title: rule.displayName, detail: rule.name.isEmpty ? rule.direction.title : rule.topicFilter,
                                    isHeld: center.heldRuleIDs.contains(rule.id),
                                    isSelected: center.selection == .mqtt(rule.id)) {
                                center.selection = .mqtt(rule.id)
                            }
                        }
                        if center.mqttRules.isEmpty { emptyLine("No MQTT rules yet") }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }

            HStack(spacing: 6) {
                DropdownMenu("Add Rule", systemImage: "plus") {
                    [.header("HTTP"),
                     .button("Map Local") { center.addHTTPRule(kind: .mapLocal) },
                     .button("Map Remote") { center.addHTTPRule(kind: .mapRemote) },
                     .button("Rewrite") { center.addHTTPRule(kind: .rewrite) },
                     .divider,
                     .header("MQTT"),
                     .button("MQTT Rewrite") { center.addMQTTRule() }]
                }
                .help("Add a rule")
                Spacer()
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }

    private func detail(_ rule: HTTPRule) -> String {
        let method = rule.method.map { "\($0) " } ?? ""
        if rule.name.trimmingCharacters(in: .whitespaces).isEmpty { return method + rule.kind.title }
        return method + (rule.pattern.isEmpty ? "No pattern" : rule.pattern)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            CapsLabel(title)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)
            content()
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }
}

/// One rule in the list: on/off switch, kind pill, name and pattern.
struct RuleRow: View {
    @Binding var isOn: Bool
    let pill: String
    let color: Color
    let title: String
    let detail: String
    /// Switched on, but waiting for Pro (Free runs fewer at a time).
    var isHeld = false
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    TypePill(text: pill, color: color, fixedWidth: 58)
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text(detail)
                        .font(Theme.monoSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isHeld { NeedsProBadge() }
                }
            }
            Spacer(minLength: 4)
            Toggle("Enabled", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Theme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent.opacity(0.35), lineWidth: 0.5)
            }
        }
        .opacity(isOn ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

/// Shown when no rule is selected: what each kind does, with a button to start one.
struct RulesEmptyState: View {
    let center: RewriteCenter

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Change traffic without changing your app")
                    .font(.system(size: 15, weight: .semibold))
                Text("Rules match requests by URL and MQTT messages by topic. Right-click anything in the timeline to start from it.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                card(.mapLocal, symbol: "doc.text", text: "Answer with a response you write, or a file on this Mac. The server is never called.") {
                    center.addHTTPRule(kind: .mapLocal)
                }
                card(.mapRemote, symbol: "arrow.uturn.right", text: "Send requests to another server, such as staging or localhost, keeping the path.") {
                    center.addHTTPRule(kind: .mapRemote)
                }
                card(.rewrite, symbol: "pencil.line", text: "Edit the URL, headers, query, body, JSON values or status on the way through.") {
                    center.addHTTPRule(kind: .rewrite)
                }
                RuleKindCard(title: "MQTT Rewrite", pill: "MQTT", color: Theme.mqtt, symbol: "antenna.radiowaves.left.and.right",
                             text: "Change the topic, payload, JSON values or retain flag of messages, through a forwarder or over WebSockets.") {
                    center.addMQTTRule()
                }
            }
            .frame(maxWidth: 560)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ kind: HTTPRule.Kind, symbol: String, text: String, action: @escaping () -> Void) -> some View {
        RuleKindCard(title: kind.title, pill: Theme.pillText(for: kind), color: Theme.color(for: kind), symbol: symbol, text: text, action: action)
    }
}

struct RuleKindCard: View {
    let title: String
    let pill: String
    let color: Color
    let symbol: String
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(color)
                        .frame(width: 26, height: 26)
                        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.hairline))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(title) rule")
    }
}

// MARK: HTTP editor

/// Edits one HTTP rule: name, match, then the kind's own settings.
struct HTTPRuleEditor: View {
    @Binding var rule: HTTPRule
    let rows: [TrafficRow]

    static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
    /// "Any" (stored as an empty string) and then every method, for a method dropdown.
    static let methodOptions: [(value: String, title: String)] = [("", "Any")] + methods.map { ($0, $0) }

    var body: some View {
        let matches = RewriteCenter.matchingURLs(rule, in: rows)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    TextField("Name", text: $rule.name, prompt: Text(rule.pattern.isEmpty ? "Untitled rule" : rule.pattern))
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    PillSegments(options: HTTPRule.Kind.allCases.map { ($0, $0.title) }, selection: $rule.kind)
                        .frame(width: 290)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    FieldGroup(label: "Method") {
                        Dropdown(title: "Method", selection: Binding(get: { rule.method ?? "" }, set: { rule.method = $0.isEmpty ? nil : $0 }),
                                 options: Self.methodOptions, monospaced: true)
                            .frame(width: 96)
                    }
                    FieldGroup(label: "URL pattern") {
                        BoxedTextField(title: "Pattern", text: $rule.pattern, prompt: "api.example.com/v2/*", monospaced: true)
                    }
                }
                MatchSummary(count: matches.count, noun: "request", example: matches.first, isEmptyPattern: rule.pattern.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            switch rule.kind {
            case .mapLocal:
                MapLocalEditor(response: $rule.mapLocal)
            case .mapRemote:
                MapRemoteEditor(rule: $rule, example: matches.first)
            case .rewrite:
                OperationsEditor(operations: $rule.operations)
            }
        }
    }
}

/// "Matches 12 requests in this session · https://…" under the pattern.
struct MatchSummary: View {
    let count: Int
    let noun: String
    let example: String?
    let isEmptyPattern: Bool

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(color: count > 0 ? Theme.success : Theme.neutral)
            if isEmptyPattern {
                Text("Enter a pattern; * matches anything").foregroundStyle(.secondary)
            } else if count == 0 {
                Text("Nothing in this session matches yet").foregroundStyle(.secondary)
            } else {
                Text("Matches \(count >= 200 ? "200+" : count.formatted()) \(noun)\(count == 1 ? "" : "s") in this session")
                if let example {
                    Text(example)
                        .font(Theme.monoSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .font(.system(size: 12))
    }
}

/// Map Local: status, headers and a body typed in or read from a file.
struct MapLocalEditor: View {
    @Binding var response: MapLocalResponse
    @State private var source: Source = .inline

    enum Source: String, CaseIterable, Identifiable {
        case inline = "Body", file = "File"
        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                FieldGroup(label: "Status") {
                    HStack(spacing: 8) {
                        TextField("Status", value: $response.statusCode, format: .number.grouping(.never))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, design: .monospaced))
                            .frame(width: 44)
                            .boxed()
                        Text(BreakpointEditor.reasonPhrase(response.statusCode))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.color(forStatus: response.statusCode))
                    }
                }
                HeaderEditor(rows: $response.editableHeaders)
                Text("Content-Length is set for you. Without a Content-Type, a file's extension picks one.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(width: 320)
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    PillSegments(options: Source.allCases.map { ($0, $0.rawValue) }, selection: $source)
                        .frame(width: 130)
                    Spacer()
                    if source == .inline {
                        Text(bodySummary)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        Button("Format") {
                            if let pretty = Formatting.prettyJSON(Array(response.body.utf8)) { response.body = pretty }
                        }
                        .buttonStyle(ChipButtonStyle())
                        .disabled(Formatting.prettyJSON(Array(response.body.utf8)) == nil)
                        .help("Pretty-print the JSON")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                if source == .inline {
                    CodeEditor(text: $response.body, highlightJSON: Formatting.prettyJSON(Array(response.body.utf8)) != nil || response.body.isEmpty)
                } else {
                    fileSource
                }
            }
        }
        .onAppear {
            source = (response.filePath ?? "").isEmpty ? .inline : .file
        }
        .onChange(of: source) {
            if source == .inline { response.filePath = nil } else if response.filePath == nil { response.filePath = "" }
        }
    }

    private var bodySummary: String {
        let bytes = Array(response.body.utf8)
        guard !bytes.isEmpty else { return "Empty" }
        let size = "\(bytes.count.formatted()) byte\(bytes.count == 1 ? "" : "s")"
        return Formatting.prettyJSON(bytes) != nil ? "\(size) · valid JSON" : size
    }

    private var fileSource: some View {
        let path = response.filePath ?? ""
        let info = FileStatus(path: path)
        return VStack(alignment: .leading, spacing: 14) {
            FieldGroup(label: "File") {
                HStack(spacing: 8) {
                    BoxedTextField(title: "Path", text: Binding(get: { response.filePath ?? "" }, set: { response.filePath = $0 }),
                                   prompt: "~/Mocks/devices.json", monospaced: true)
                    Button("Choose…", action: choose)
                        .buttonStyle(ChipButtonStyle())
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (path as NSString).expandingTildeInPath)])
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(ChipButtonStyle())
                    .disabled(!info.exists)
                    .help("Show in Finder")
                }
            }
            HStack(spacing: 7) {
                StatusDot(color: info.exists ? Theme.success : (path.isEmpty ? Theme.neutral : Theme.failure))
                Text(info.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text("The file is read on every request, so saving it in your editor changes the next response. If it can't be read, the app gets a 500 that says why.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use File"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        response.filePath = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    struct FileStatus {
        var exists = false
        var summary = "Choose a file to answer with"

        init(path: String) {
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            let expanded = (trimmed as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: expanded) else {
                summary = "No file at this path yet"
                return
            }
            exists = true
            let size = (attributes[.size] as? Int) ?? 0
            let modified = (attributes[.modificationDate] as? Date).map { " · changed \($0.formatted(.relative(presentation: .named)))" } ?? ""
            summary = "\(Formatting.byteCount(size))\(modified)"
        }
    }
}

/// Map Remote: the destination and a live before/after preview.
struct MapRemoteEditor: View {
    @Binding var rule: HTTPRule
    let example: String?

    var body: some View {
        let from = example ?? sampleURL
        let to = rule.mapRemote.destination(for: from, pattern: rule.pattern)
        VStack(alignment: .leading, spacing: 18) {
            FieldGroup(label: "Send to") {
                BoxedTextField(title: "Destination", text: $rule.mapRemote.url, prompt: "http://localhost:3000", monospaced: true)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep the original Host header").font(.system(size: 12.5))
                    Text("For servers that pick the site by Host, such as a local reverse proxy.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Keep Host", isOn: $rule.mapRemote.preserveHostHeader)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            FieldGroup(label: example == nil ? "Preview · example URL" : "Preview · latest match") {
                VStack(alignment: .leading, spacing: 10) {
                    previewLine("From", from, color: .secondary)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    if let to {
                        previewLine("To", to, color: Theme.accent)
                    } else {
                        previewLine("To", rule.mapRemote.url.isEmpty ? "Enter an http:// or https:// destination"
                                                                     : "Not an absolute http:// or https:// URL", color: Theme.failure)
                    }
                }
                .padding(14)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.hairline))
            }
            VStack(alignment: .leading, spacing: 6) {
                hint("https://staging.example.com", "keeps the path and query, swaps scheme, host and port")
                hint("http://localhost:3000/api/*", "replaces the path; each * is what the pattern's * matched")
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sampleURL: String {
        let base = rule.pattern.isEmpty ? "api.example.com/v2/devices" : rule.pattern.replacingOccurrences(of: "*", with: "devices")
        return base.contains("://") ? base : "https://" + base
    }

    private func previewLine(_ label: String, _ url: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label.uppercased())
                .font(Theme.label)
                .kerning(0.6)
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .leading)
            Text(url)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func hint(_ example: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(example).font(Theme.monoSmall).foregroundStyle(.secondary)
            Text(text).font(.system(size: 11.5)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: Rewrite operations

/// The list of edits a Rewrite rule makes, request edits first.
struct OperationsEditor: View {
    @Binding var operations: [RewriteOperation]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CapsLabel("Edits · applied in order")
                    Spacer()
                    DropdownMenu("Add Edit", systemImage: "plus") {
                        [RewriteOperation.Phase.request, .response].flatMap { phase -> [DropdownItem] in
                            [DropdownItem.header(phase == .request ? "Request" : "Response")]
                                + RewriteOperation.Target.allCases.filter { $0.applies(to: phase) }.map { target -> DropdownItem in
                                    .button(target.title) { add(phase, target) }
                                }
                        }
                    }
                }
                if operations.isEmpty {
                    Text("No edits yet. Add one to change the request before it's sent or the response before the app sees it.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                ForEach($operations) { $operation in
                    OperationRow(operation: $operation) {
                        operations.removeAll { $0.id == operation.id }
                    }
                }
            }
            .padding(20)
        }
    }

    private func add(_ phase: RewriteOperation.Phase, _ target: RewriteOperation.Target) {
        operations.append(RewriteOperation(phase: phase, target: target, action: target.actions[0]))
    }
}

/// One edit as a card: where, what and how on top, its fields below.
struct OperationRow: View {
    @Binding var operation: RewriteOperation
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TypePill(text: operation.phase == .request ? "REQUEST" : "RESPONSE",
                         color: operation.phase == .request ? Theme.get : Theme.success, fixedWidth: 70)
                Dropdown(title: "Target", selection: targetBinding,
                         options: RewriteOperation.Target.allCases.filter { $0.applies(to: operation.phase) }.map { ($0, $0.title) },
                         size: .compact)
                    .fixedSize()
                Dropdown(title: "Action", selection: $operation.action,
                         options: operation.target.actions.map { ($0, $0.title) }, size: .compact)
                    .fixedSize()
                Spacer()
                Button {
                    operation.phase = operation.phase == .request ? .response : .request
                    if !operation.target.applies(to: operation.phase) { operation.target = .header }
                    if !operation.target.actions.contains(operation.action) { operation.action = operation.target.actions[0] }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(MiniButtonStyle())
                .help("Switch between request and response")
                Button(action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(MiniButtonStyle())
                .help("Remove this edit")
            }
            OperationFields(labels: OperationFields.labels(for: operation.target, action: operation.action), action: operation.action,
                            name: $operation.name, value: $operation.value, find: $operation.find, useRegex: $operation.useRegex)
        }
        .padding(12)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var targetBinding: Binding<RewriteOperation.Target> {
        Binding(get: { operation.target }, set: { target in
            operation.target = target
            if !target.actions.contains(operation.action) { operation.action = target.actions[0] }
        })
    }
}

/// Name, find and value fields for an edit, shown only when the edit uses them.
struct OperationFields: View {
    struct Labels {
        var name: (label: String, prompt: String)?
        var value: (label: String, prompt: String)
    }

    let labels: Labels
    let action: RewriteOperation.Action
    @Binding var name: String
    @Binding var value: String
    @Binding var find: String
    @Binding var useRegex: Bool

    /// Labels for an HTTP edit.
    static func labels(for target: RewriteOperation.Target, action: RewriteOperation.Action) -> Labels {
        let replacing = action == .replace
        switch target {
        case .url: return Labels(value: replacing ? ("Replace with", "/v3/") : ("URL", "https://api.example.com/v3/devices"))
        case .method: return Labels(value: ("Method", "POST"))
        case .status: return Labels(value: ("Status", "503"))
        case .header:
            return Labels(name: ("Header", replacing ? "All headers" : "Cache-Control"),
                          value: replacing ? ("Replace with", "") : ("Value", "no-store"))
        case .query:
            return Labels(name: replacing ? nil : ("Parameter", "page"), value: replacing ? ("Replace with", "") : ("Value", "2"))
        case .body: return Labels(value: replacing ? ("Replace with", "") : ("Body", "{\"ok\": true}"))
        case .json: return Labels(name: ("Key path", "user.plan or items[0].id"), value: ("JSON value", "\"free\", 42, true or {…}"))
        }
    }

    /// Labels for an MQTT edit.
    static func labels(for target: MQTTRewriteOperation.Target, action: RewriteOperation.Action) -> Labels {
        let replacing = action == .replace
        switch target {
        case .topic: return Labels(value: replacing ? ("Replace with", "/test/") : ("Topic", "home/test/temperature"))
        case .payload: return Labels(value: replacing ? ("Replace with", "") : ("Payload", "{\"celsius\": 48}"))
        case .json: return Labels(name: ("Key path", "celsius or readings[0]"), value: ("JSON value", "48, \"text\", true or {…}"))
        case .retain: return Labels(value: ("Retain", "true"))
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let nameLabel = labels.name {
                FieldGroup(label: nameLabel.label) {
                    BoxedTextField(title: nameLabel.label, text: $name, prompt: nameLabel.prompt, monospaced: true)
                }
                .frame(maxWidth: 200)
            }
            if action == .replace {
                FieldGroup(label: "Find") {
                    HStack(spacing: 6) {
                        BoxedTextField(title: "Find", text: $find, prompt: useRegex ? "max-age=\\d+" : "text to find", monospaced: true)
                        Button(".*") { useRegex.toggle() }
                            .buttonStyle(MiniButtonStyle(selected: useRegex))
                            .help(useRegex ? "Regular expression; use $1 in the replacement" : "Plain text; click for a regular expression")
                    }
                }
            }
            if action != .remove {
                FieldGroup(label: labels.value.label) {
                    BoxedTextField(title: labels.value.label, text: $value, prompt: labels.value.prompt, monospaced: true)
                }
            }
        }
    }
}

// MARK: MQTT editor

/// Edits one MQTT rule: topic filter, direction and the edits.
struct MQTTRuleEditor: View {
    @Binding var rule: MQTTRule
    let rows: [TrafficRow]

    var body: some View {
        let topics = RewriteCenter.matchingTopics(rule, in: rows)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    TextField("Name", text: $rule.name, prompt: Text(rule.topicFilter.isEmpty ? "Untitled rule" : rule.topicFilter))
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    PillSegments(options: MQTTRule.Direction.allCases.map { ($0, $0.title) }, selection: $rule.direction)
                        .frame(width: 330)
                }
                FieldGroup(label: "Topic filter") {
                    BoxedTextField(title: "Topic filter", text: $rule.topicFilter, prompt: "home/+/temperature or home/#", monospaced: true)
                }
                HStack(spacing: 7) {
                    StatusDot(color: topics.isEmpty ? Theme.neutral : Theme.success)
                    if rule.topicFilter.isEmpty {
                        Text("+ matches one level, # the rest").foregroundStyle(.secondary)
                    } else if topics.isEmpty {
                        Text("No message in this session matches yet").foregroundStyle(.secondary)
                    } else {
                        Text("Matches \(topics.count) topic\(topics.count == 1 ? "" : "s")")
                        ForEach(topics.prefix(3), id: \.self) { topic in
                            Text(topic)
                                .font(Theme.monoSmall)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                }
                .font(.system(size: 12))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        CapsLabel("Edits · applied in order")
                        Spacer()
                        DropdownMenu("Add Edit", systemImage: "plus") {
                            MQTTRewriteOperation.Target.allCases.map { target -> DropdownItem in
                                .button(target.title) {
                                    rule.operations.append(MQTTRewriteOperation(target: target, action: target.actions[0],
                                                                                value: target == .retain ? "true" : ""))
                                }
                            }
                        }
                    }
                    ForEach($rule.operations) { $operation in
                        MQTTOperationRow(operation: $operation) {
                            rule.operations.removeAll { $0.id == operation.id }
                        }
                    }
                    Text("Applies to MQTT through a forwarder (Settings › MQTT) and to MQTT over WebSockets through the proxy. QoS and packet IDs are kept, so acknowledgements still match.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .padding(20)
            }
        }
    }
}

struct MQTTOperationRow: View {
    @Binding var operation: MQTTRewriteOperation
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TypePill(text: "PUBLISH", color: Theme.mqtt, fixedWidth: 70)
                Dropdown(title: "Target", selection: Binding(get: { operation.target }, set: { target in
                    operation.target = target
                    if !target.actions.contains(operation.action) { operation.action = target.actions[0] }
                }), options: MQTTRewriteOperation.Target.allCases.map { ($0, $0.title) }, size: .compact)
                    .fixedSize()
                Dropdown(title: "Action", selection: $operation.action,
                         options: operation.target.actions.map { ($0, $0.title) }, size: .compact)
                    .fixedSize()
                Spacer()
                Button(action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(MiniButtonStyle())
                .help("Remove this edit")
            }
            if operation.target == .retain {
                PillSegments(options: [("true", "Retain"), ("false", "Don't retain")], selection: $operation.value)
                    .frame(width: 220)
            } else {
                OperationFields(labels: OperationFields.labels(for: operation.target, action: operation.action), action: operation.action,
                                name: $operation.name, value: $operation.value, find: $operation.find, useRegex: $operation.useRegex)
            }
        }
        .padding(12)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.hairline))
    }

}
#endif
