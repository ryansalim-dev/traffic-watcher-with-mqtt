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
            Label("Breakpoints", systemImage: symbol)
        }
        .foregroundStyle(center.isActive ? Color.orange : Color.secondary)
        .help(help)
    }

    private var symbol: String {
        if !center.isAllowed { return "pause.octagon" }
        return center.isEnabled ? "pause.octagon.fill" : "pause.octagon"
    }

    private var help: String {
        if !center.isAllowed { return "Breakpoints are part of Traffic Watcher Pro" }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if isRequest {
                    HStack(spacing: 8) {
                        TextField("Method", text: $method)
                            .frame(width: 90)
                        TextField("URL", text: $url)
                    }
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                } else {
                    HStack(spacing: 8) {
                        Text("Status").foregroundStyle(.secondary)
                        TextField("Status", value: $status, format: .number.grouping(.never))
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                        Text(Self.reasonPhrase(status))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                Text("Headers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextEditor(text: $headersText)
                    .font(.callout.monospaced())
                    .frame(minHeight: 110, idealHeight: 150)
                    .border(Color(nsColor: .separatorColor))
                HStack {
                    Text("Body").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(Formatting.byteCount(currentBody.count)).font(.caption).foregroundStyle(.tertiary)
                }
                if let binaryBody {
                    Text("Binary body (\(Formatting.byteCount(binaryBody.count))). It is passed on unchanged.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .background(Color(nsColor: .textBackgroundColor))
                        .border(Color(nsColor: .separatorColor))
                } else {
                    TextEditor(text: $bodyText)
                        .font(.callout.monospaced())
                        .frame(minHeight: 160)
                        .border(Color(nsColor: .separatorColor))
                }
            }
            .padding(16)
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 560, idealHeight: 620)
        .onAppear(perform: load)
        .interactiveDismissDisabled()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(isRequest ? "Request paused before it was sent" : "Response paused before the app sees it")
                    .font(.headline)
                Text(item.title)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Paused \(item.pausedAt.formatted(date: .omitted, time: .standard)). It continues unchanged after \(minutes) if left alone.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            let waiting = center.paused.count - 1
            if waiting > 0 {
                Text("\(waiting) more waiting")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Abort", role: .destructive) { center.abort(item.id) }
                .help(isRequest ? "Don't send it; the app gets a 502 error" : "Drop the response; the app gets a 502 error")
            Spacer()
            Button("Reset") { load() }
            Button("Continue Unchanged") { center.resumeUnchanged(item.id) }
            Button(isRequest ? "Send" : "Return to App") { resume() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
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
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(feature) is part of Traffic Watcher Pro").font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if showsUpgrade { SettingsLink { Text("Upgrade…") } }
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
#endif
