#if os(macOS)
import AppCore
import AppKit
import MQTTCore
import ProxyCore
import SwiftUI

/// Detail pane for the selected timeline row.
struct InspectorView: View {
    let model: CaptureViewModel

    var body: some View {
        if let row = model.selectedRow {
            Group {
                switch row.event {
                case .httpExchange(let exchange):
                    HTTPInspector(exchange: exchange)
                case .mqtt(let capture):
                    MQTTInspector(capture: capture) {
                        if model.prepareReplay(of: row) { model.composer.isPresented = true }
                    }
                case .webSocketMessage(let message):
                    WebSocketInspector(message: message)
                case .tunnelOpened(let tunnel):
                    NoticeView(symbol: "lock.fill", title: "Encrypted tunnel to \(tunnel.host):\(String(tunnel.port))",
                               message: "This connection was relayed without decrypting it, either because HTTPS decryption is off or the host is on the bypass list.")
                case .tunnelClosed(_, let fromClient, let fromServer):
                    NoticeView(symbol: "lock.open", title: "Tunnel closed",
                               message: "\(Formatting.byteCount(fromClient)) sent, \(Formatting.byteCount(fromServer)) received.")
                case .tlsInterceptionFailed(let host, let port, let reason):
                    PinnedHostInspector(model: model, host: host, port: port, reason: reason)
                case .mqttDecodingFailed(_, let reason):
                    NoticeView(symbol: "exclamationmark.triangle", title: "MQTT stream could not be decoded",
                               message: "\(reason)\n\nThe bytes were still forwarded unchanged; only the capture of this connection stopped.")
                case .webSocketDecodingFailed(_, let reason):
                    NoticeView(symbol: "exclamationmark.triangle", title: "WebSocket stream could not be decoded",
                               message: "\(reason)\n\nThe bytes were still forwarded unchanged.")
                }
            }
            .id(row.id)
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "sidebar.right",
                                   description: Text("Select a request, packet or message to inspect it."))
        }
    }
}

// MARK: HTTP

struct HTTPInspector: View {
    let exchange: HTTPExchange
    @State var part: Part = .response

    enum Part: String, CaseIterable, Identifiable {
        case request = "Request", response = "Response"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TypePill(text: exchange.method.uppercased(), color: Theme.color(forPill: exchange.method.uppercased(), kind: .http),
                             fixedWidth: nil)
                    StatusPill(code: exchange.statusCode)
                    Spacer()
                    Text("\(Formatting.duration(exchange.duration)) · \(Formatting.byteCount(exchange.responseBody.count))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                URLText(url: exchange.url)
                if let error = exchange.error {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.failure).font(.callout)
                }
                if let stages = exchange.breakpoint {
                    Label(Self.breakpointNote(stages), systemImage: "pause.circle.fill")
                        .foregroundStyle(Theme.warning)
                        .font(.callout)
                }
                Picker("Part", selection: $part) {
                    ForEach(Part.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.top, 2)
            }
            .padding(16)

            Divider()

            let headers = part == .request ? exchange.requestHeaders : exchange.responseHeaders
            let body = part == .request ? exchange.requestBody : exchange.responseBody
            VSplitView {
                HeadersView(headers: headers)
                    .frame(minHeight: 90, idealHeight: 170)
                BodyView(bytes: body, contentType: headers.first { $0.name.lowercased() == "content-type" }?.value)
                    .frame(minHeight: 120)
            }
        }
    }
}

extension HTTPInspector {
    static func breakpointNote(_ stages: BreakpointStages) -> String {
        switch stages {
        case .request: "Paused at a breakpoint before sending; shown as sent"
        case .response: "Paused at a breakpoint before returning; shown as returned"
        default: "Paused at breakpoints; shown as sent and returned"
        }
    }
}

/// Status code and reason with a colored dot, such as "● 200 OK".
struct StatusPill: View {
    let code: Int?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(code.map { "\($0) \(Self.reason(for: $0))".trimmingCharacters(in: .whitespaces) } ?? "No response")
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .layoutPriority(1)
    }

    private var color: Color { Theme.color(forStatus: code) }

    static func reason(for code: Int) -> String {
        switch code {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 206: "Partial Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 304: "Not Modified"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: ""
        }
    }
}

/// A URL in monospace with the host emphasized and the rest dimmed.
struct URLText: View {
    let url: String

    var body: some View {
        let (lead, host, rest) = Self.split(url)
        (Text(lead).foregroundStyle(.tertiary)
            + Text(host).foregroundStyle(.primary).fontWeight(.medium)
            + Text(rest).foregroundStyle(.secondary))
            .font(.system(size: 12.5, design: .monospaced))
            .lineLimit(4)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Splits "https://host/path" into ("https://", "host", "/path").
    static func split(_ url: String) -> (String, String, String) {
        let schemeEnd = url.range(of: "://")?.upperBound ?? url.startIndex
        let afterScheme = url[schemeEnd...]
        let pathStart = afterScheme.firstIndex(of: "/") ?? url.endIndex
        return (String(url[..<schemeEnd]), String(url[schemeEnd..<pathStart]), String(url[pathStart...]))
    }
}

struct HeadersView: View {
    let headers: [CapturedHeader]

    var body: some View {
        if headers.isEmpty {
            Text("No headers").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        GridRow {
                            Text(header.name)
                                .foregroundStyle(.tertiary)
                                .gridColumnAlignment(.trailing)
                            Text(header.value)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(Theme.mono)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }
}

// MARK: Body

/// Shows a body or payload as pretty JSON, text or a hex dump, with a toggle for the raw hex.
struct BodyView: View {
    let bytes: [UInt8]
    let contentType: String?
    @State private var showHex = false

    var body: some View {
        let presentation = showHex ? BodyPresentation.binary(hexDump: Formatting.hexDump(Array(bytes.prefix(1_000_000))))
                                   : Formatting.present(bytes, contentType: contentType)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(kindLabel(presentation)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(Formatting.byteCount(bytes.count)).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if !bytes.isEmpty {
                    Toggle("Hex", isOn: $showHex).toggleStyle(.button).controlSize(.small)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text(presentation), forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if case .empty = presentation {
                Text("No body").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        Text(text(presentation))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .fixedSize()
                            .padding(12)
                            .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    private func text(_ presentation: BodyPresentation) -> String {
        switch presentation {
        case .empty: ""
        case .json(let s), .text(let s): s
        case .binary(let dump): dump
        }
    }

    private func kindLabel(_ presentation: BodyPresentation) -> String {
        switch presentation {
        case .empty: "EMPTY"
        case .json: "JSON"
        case .text: "TEXT"
        case .binary: "HEX"
        }
    }
}

// MARK: MQTT

struct MQTTInspector: View {
    let capture: MQTTCaptureEvent
    var onReplay: (() -> Void)?

    var body: some View {
        let event = capture.event
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    TypePill(text: "\(event.packet.type)".uppercased(), color: Theme.mqtt, fixedWidth: nil)
                    Text("MQTT \(event.version)").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if case .publish = event.packet, let onReplay {
                        Button {
                            onReplay()
                        } label: {
                            Label("Replay…", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .fixedSize()
                        .help("Send this message again, edited if you like (Pro)")
                    }
                }
                Text("\(capture.broker) · \(event.direction == .clientToBroker ? "client → broker" : "broker → client")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(16)
            Divider()
            VSplitView {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(Array(MQTTDescriber.rows(for: event).enumerated()), id: \.offset) { _, row in
                            GridRow {
                                Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                Text(row.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .font(.callout)
                    .padding(12)
                }
                .frame(minHeight: 100, idealHeight: 190)

                if case .publish(let publish) = event.packet {
                    BodyView(bytes: publish.payload, contentType: nil).frame(minHeight: 120)
                } else {
                    BodyView(bytes: event.frame.rawBytes, contentType: "application/octet-stream").frame(minHeight: 120)
                }
            }
        }
    }
}

// MARK: WebSocket

struct WebSocketInspector: View {
    let message: WebSocketMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TypePill(text: "\(message.opcode)".uppercased(), color: Theme.webSocket, fixedWidth: nil)
                    Text(message.direction == .clientToServer ? "client → server" : "server → client")
                        .foregroundStyle(.secondary)
                }
                Text(message.url).font(.callout.monospaced()).textSelection(.enabled)
            }
            .padding(12)
            Divider()
            BodyView(bytes: message.payload, contentType: message.opcode == .binary ? "application/octet-stream" : nil)
        }
    }
}

// MARK: Notices

struct PinnedHostInspector: View {
    let model: CaptureViewModel
    let host: String
    let port: Int
    let reason: String

    var body: some View {
        let bypassed = model.configuration.bypassHosts.contains(host)
        ContentUnavailableView {
            Label("\(host) rejected our certificate", systemImage: "lock.trianglebadge.exclamationmark")
        } description: {
            Text("The app most likely pins its certificates, or the Wiretide root CA isn't trusted on this device yet.\n\n\(reason)")
        } actions: {
            if bypassed {
                Label("Bypassed: relayed without decrypting", systemImage: "checkmark.circle").foregroundStyle(.green)
            } else {
                Button("Bypass \(host)") { model.bypass(host: host) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct NoticeView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
    }
}
#endif
