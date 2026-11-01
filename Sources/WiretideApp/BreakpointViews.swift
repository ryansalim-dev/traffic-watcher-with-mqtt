#if os(macOS)
import AppCore
import ProxyCore
import SwiftUI

/// Toolbar switch for breakpoints. Without Pro it still toggles, but shows a lock and explains.
struct BreakpointsToggle: View {
    @Bindable var center: BreakpointCenter

    var body: some View {
        Button {
            center.isEnabled.toggle()
        } label: {
            Label {
                Text("Breakpoints")
            } icon: {
                Image(systemName: symbol)
                    .overlay(alignment: .topTrailing) {
                        if !center.paused.isEmpty {
                            Text(center.paused.count.formatted())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color(red: 0.1, green: 0.07, blue: 0))
                                .padding(.horizontal, 3)
                                .frame(minWidth: 14, minHeight: 14)
                                .background(Theme.put, in: Capsule())
                                .offset(x: 8, y: -7)
                        }
                    }
            }
        }
        .foregroundStyle(center.isActive ? Theme.warning : Color.secondary)
        .help(help)
    }

    private var symbol: String {
        if !center.isAllowed { return "pause.circle" }
        return center.isEnabled ? "pause.circle.fill" : "pause.circle"
    }

    private var help: String {
        if !center.isAllowed { return "Breakpoints are part of Wiretide Pro" }
        let count = center.rules.filter(\.isEnabled).count
        return center.isEnabled
            ? "Breakpoints on: \(count) rule\(count == 1 ? "" : "s") can pause requests (⇧⌘B)"
            : "Breakpoints off: nothing pauses (⇧⌘B)"
    }
}

/// The editor shown while an exchange is paused: change the request or response, then let it go or drop it.
struct BreakpointEditor: View {
    let center: BreakpointCenter
    let item: PausedExchange

    @State private var method = ""
    @State private var url = ""
    @State private var status = 200
    @State private var headersText = ""
    @State private var bodyText = ""
    /// Set when the body isn't text; it is then passed on untouched.
    @State private var binaryBody: [UInt8]?

    private var isRequest: Bool { item.stage == .request }

    @State private var bodyFormat: BodyFormat = .text

    enum BodyFormat: String, CaseIterable, Identifiable {
        case json = "JSON", text = "Text"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    if isRequest {
                        FieldGroup(label: "Method") {
                            BoxedTextField(title: "Method", text: $method, monospaced: true)
                        }
                        FieldGroup(label: "URL") {
                            TextField("URL", text: $url, axis: .vertical)
                                .labelsHidden()
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5, design: .monospaced))
                                .lineLimit(1...4)
                                .padding(.vertical, 6)
                                .boxed()
                        }
                    } else {
                        FieldGroup(label: "Status") {
                            HStack(spacing: 8) {
                                TextField("Status", value: $status, format: .number.grouping(.never))
                                    .labelsHidden()
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .frame(width: 44)
                                    .boxed()
                                Text(Self.reasonPhrase(status))
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(Theme.color(forStatus: status))
                            }
                        }
                    }
                    FieldGroup(label: "Headers · one per line") {
                        CodeEditor(text: $headersText, fontSize: 12)
                            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(width: 340)
                .frame(maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }

                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        if binaryBody == nil {
                            Picker("Format", selection: $bodyFormat) {
                                ForEach(BodyFormat.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 130)
                        } else {
                            CapsLabel("Body")
                        }
                        Spacer()
                        Text(bodySummary)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        if binaryBody == nil {
                            Button("Format") {
                                if let pretty = Formatting.prettyJSON(Array(bodyText.utf8)) { bodyText = pretty }
                            }
                            .buttonStyle(ChipButtonStyle())
                            .disabled(Formatting.prettyJSON(Array(bodyText.utf8)) == nil)
                            .help("Pretty-print the JSON")
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    if let binaryBody {
                        Text("Binary body (\(Formatting.byteCount(binaryBody.count))). It is passed on unchanged.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        CodeEditor(text: $bodyText, highlightJSON: bodyFormat == .json)
                    }
                }
            }
            footer
        }
        .frame(minWidth: 820, idealWidth: 880, minHeight: 560, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Theme.accent)
        .onAppear(perform: load)
        .interactiveDismissDisabled()
    }

    private var bodySummary: String {
        let body = currentBody
        guard !body.isEmpty else { return "Empty" }
        let size = "\(body.count.formatted()) byte\(body.count == 1 ? "" : "s")"
        if binaryBody == nil, Formatting.prettyJSON(body) != nil { return "\(size) · valid JSON" }
        return size
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "pause.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.warning)
                .frame(width: 28, height: 28)
                .background(Theme.warning.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(isRequest ? "Request paused" : "Response paused")
                        .font(.system(size: 14, weight: .semibold))
                    Text(isRequest ? "before it was sent" : "before the app sees it")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    TypePill(text: item.request.method.uppercased(),
                             color: Theme.color(forPill: item.request.method.uppercased(), kind: .http), fixedWidth: nil)
                    URLText(url: item.request.url)
                        .lineLimit(1)
                }
            }
            Spacer()
            let waiting = center.paused.count - 1
            if waiting > 0 {
                Text("\(waiting) more waiting")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.warning.opacity(0.15), in: Capsule())
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Abort", role: .destructive) { center.abort(item.id) }
                .buttonStyle(ChipButtonStyle())
                .help(isRequest ? "Don't send it; the app gets a 502 error" : "Drop the response; the app gets a 502 error")
            Text("Paused \(item.pausedAt.formatted(date: .omitted, time: .standard)) · continues unchanged after \(minutes)")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            Button("Reset Edits") { load() }
                .buttonStyle(ChipButtonStyle())
            Button("Continue") { center.resumeUnchanged(item.id) }
                .buttonStyle(ChipButtonStyle())
                .help("Let it through without your edits")
            Button {
                resume()
            } label: {
                HStack(spacing: 6) {
                    Text(isRequest ? "Send edited" : "Return edited")
                    Text("⌘↩").opacity(0.7)
                }
            }
            .buttonStyle(ChipButtonStyle(prominent: true))
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var minutes: String {
        let seconds = Int(center.timeout.components.seconds)
        return seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) s"
    }

    private var currentBody: [UInt8] { binaryBody ?? Array(bodyText.utf8) }

    static func reasonPhrase(_ code: Int) -> String {
        let common: [Int: String] = [
            200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 301: "Moved Permanently", 302: "Found",
            304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request",
            401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 409: "Conflict", 422: "Unprocessable Content",
            429: "Too Many Requests", 500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable",
            504: "Gateway Timeout",
        ]
        return common[code] ?? HTTPURLResponse.localizedString(forStatusCode: code).capitalized
    }

    private func load() {
        let headers = isRequest ? item.request.headers : item.response?.headers ?? []
        let bytes = isRequest ? item.request.body : item.response?.body ?? []
        method = item.request.method
        url = item.request.url
        status = item.response?.statusCode ?? 200
        headersText = HeaderText.format(headers)
        if let text = String(bytes: bytes, encoding: .utf8) {
            bodyText = text
            binaryBody = nil
            bodyFormat = text.isEmpty || Formatting.prettyJSON(bytes) != nil ? .json : .text
        } else {
            bodyText = ""
            binaryBody = bytes
        }
    }

    private func resume() {
        let headers = HeaderText.parse(headersText)
        if isRequest {
            center.resume(item.id, request: HTTPRequestDraft(method: method.trimmingCharacters(in: .whitespaces).uppercased(),
                                                             url: url.trimmingCharacters(in: .whitespaces),
                                                             headers: headers, body: currentBody))
        } else {
            center.resume(item.id, response: HTTPResponseDraft(statusCode: status, headers: headers, body: currentBody))
        }
    }
}

/// Settings › Breakpoints: the rules and the master switch.
struct BreakpointSettings: View {
    @Bindable var center: BreakpointCenter

    private static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var body: some View {
        Form {
            if !center.isAllowed {
                ProNotice(feature: "Breakpoints", detail: "Your rules are kept, but requests only pause with Pro. See the License tab.", showsUpgrade: false)
            }
            Section {
                Toggle("Pause requests that match a rule", isOn: $center.isEnabled)
            } footer: {
                Text("A paused request waits for you to edit it, send it or abort it. Anything left alone continues unchanged after 5 minutes.")
                    .foregroundStyle(.secondary)
            }
            Section {
                if center.rules.isEmpty {
                    Text("No rules yet. Add one here, or right-click a request in the timeline.")
                        .foregroundStyle(.secondary)
                }
                ForEach($center.rules) { $rule in
                    HStack(spacing: 8) {
                        Toggle("Enabled", isOn: $rule.isEnabled).labelsHidden()
                        Picker("Method", selection: Binding(get: { $rule.wrappedValue.method ?? "" }, set: { $rule.wrappedValue.method = $0.isEmpty ? nil : $0 })) {
                            Text("Any").tag("")
                            ForEach(Self.methods, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        TextField("Pattern", text: $rule.pattern, prompt: Text("api.example.com/v2/*"))
                            .labelsHidden()
                            .font(.callout.monospaced())
                        Picker("Stop at", selection: Binding(get: { StageChoice($rule.wrappedValue.stages) }, set: { $rule.wrappedValue.stages = $0.stages })) {
                            ForEach(StageChoice.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 105)
                        Button {
                            center.rules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this rule")
                    }
                    .opacity(rule.isEnabled ? 1 : 0.5)
                }
                Button("Add Rule") { center.rules.append(BreakpointRule(pattern: "")) }
            } header: {
                Text("Rules")
            } footer: {
                Text("Patterns match the whole URL. * matches anything; leave out the scheme to match http and https.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    enum StageChoice: String, CaseIterable, Identifiable {
        case request = "Request", response = "Response", both = "Both"
        var id: String { rawValue }

        init(_ stages: BreakpointStages) {
            switch stages {
            case .request: self = .request
            case .response: self = .response
            default: self = .both
            }
        }

        var stages: BreakpointStages {
            switch self {
            case .request: .request
            case .response: .response
            case .both: [.request, .response]
            }
        }
    }
}

/// "This is a Pro feature" row with a way to the License settings.
struct ProNotice: View {
    let feature: String
    let detail: String
    /// Off inside Settings, where the License tab is one click away.
    var showsUpgrade = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(feature) is part of Wiretide Pro").font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if showsUpgrade { SettingsLink { Text("Upgrade…") } }
        }
        .padding(10)
        .background(Theme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
#endif
