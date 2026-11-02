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
    @State private var part: Part = .response
    @State private var tab: Tab = .body

    enum Part: String, CaseIterable, Identifiable {
        case request = "Request", response = "Response"
        var id: String { rawValue }
    }

    enum Tab: Hashable { case headers, body, raw, timing }

    var body: some View {
        let headers = part == .request ? exchange.requestHeaders : exchange.responseHeaders
        let bytes = part == .request ? exchange.requestBody : exchange.responseBody
        let contentType = part == .request ? exchange.requestContentType : exchange.responseContentType
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TypePill(text: exchange.method.uppercased(), color: Theme.color(forPill: exchange.method.uppercased(), kind: .http),
                             fixedWidth: nil)
                    StatusPill(code: exchange.statusCode)
                    Spacer()
                    Text("\(Formatting.duration(exchange.duration)) · \(Formatting.compactByteCount(exchange.responseBody.count))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                URLText(url: exchange.url)
                if let error = exchange.error {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.failure).font(.system(size: 12))
                }
                if let stages = exchange.breakpoint {
                    Label(Self.breakpointNote(stages), systemImage: "pause.circle.fill")
                        .foregroundStyle(Theme.warning)
                        .font(.system(size: 12))
                }
                TimingSummary(timing: exchange.timing, total: exchange.duration)
                    .padding(.top, 2)
                PillSegments(options: Part.allCases.map { ($0, $0.rawValue) }, selection: $part)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            InspectorTabs(tabs: [(Tab.headers, "Headers", headers.count), (.body, "Body", nil), (.raw, "Raw", nil), (.timing, "Timing", nil)],
                          selection: $tab, trailing: tab == .body ? contentType : nil)

            switch tab {
            case .headers:
                KeyValueList(rows: headers.map { ($0.name, $0.value) })
            case .body:
                BodyPanel(bytes: bytes, contentType: contentType)
                    .id(part)
            case .raw:
                CodeText(text: part == .request ? exchange.rawRequest : exchange.rawResponse)
            case .timing:
                TimingDetail(exchange: exchange)
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
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .layoutPriority(1)
    }

    private var color: Color { Theme.color(forStatus: code) }

    static func reason(for code: Int) -> String { HTTPStatus.reason(for: code) }
}

/// A URL in monospace with the host bright and the path dimmed. The scheme is left out, as in the mockup;
/// the Raw tab and Copy as cURL keep the full URL.
struct URLText: View {
    let url: String

    var body: some View {
        let (_, host, rest) = Self.split(url)
        (Text(host).foregroundStyle(.primary).fontWeight(.medium) + Text(rest).foregroundStyle(.secondary))
            .font(.system(size: 12.5, design: .monospaced))
            .lineLimit(4)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .help(url)
    }

    /// Splits "https://host/path" into ("https://", "host", "/path").
    static func split(_ url: String) -> (String, String, String) {
        let schemeEnd = url.range(of: "://")?.upperBound ?? url.startIndex
        let afterScheme = url[schemeEnd...]
        let pathStart = afterScheme.firstIndex(of: "/") ?? url.endIndex
        return (String(url[..<schemeEnd]), String(url[schemeEnd..<pathStart]), String(url[pathStart...]))
    }
}

// MARK: MQTT

struct MQTTInspector: View {
    let capture: MQTTCaptureEvent
    var onReplay: (() -> Void)?
    @State private var tab: Tab = .payload

    enum Tab: Hashable { case payload, details, hex }

    var body: some View {
        let event = capture.event
        let publish: MQTTPublish? = if case .publish(let p) = event.packet { p } else { nil }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TypePill(text: "\(event.packet.type)".uppercased(), color: Theme.mqtt, fixedWidth: nil)
                    Text("MQTT \(event.version)").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(capture.timestamp.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))) · \(Formatting.compactByteCount(event.frame.rawBytes.count))")
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let publish {
                    TopicPathText(path: event.resolvedTopic ?? publish.topic)
                }
                Text("\(capture.broker) · \(event.direction == .clientToBroker ? "client → broker" : "broker → client")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if publish != nil, let onReplay {
                    HStack(spacing: 8) {
                        Button {
                            onReplay()
                        } label: {
                            Label("Replay…", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(ChipButtonStyle(prominent: true))
                        .help("Send this message again, edited if you like (Pro)")
                        Button {
                            copyToPasteboard(event.resolvedTopic ?? publish?.topic ?? "")
                        } label: {
                            Label("Copy topic", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(ChipButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            let tabs: [(tab: Tab, title: String, count: Int?)] = publish == nil
                ? [(.details, "Details", nil), (.hex, "Hex", nil)]
                : [(.payload, "Payload", nil), (.details, "Details", nil), (.hex, "Hex", nil)]
            let current = publish == nil && tab == .payload ? .details : tab
            InspectorTabs(tabs: tabs, selection: Binding(get: { current }, set: { tab = $0 }),
                          trailing: "\(event.packet.type)".uppercased())

            switch current {
            case .payload:
                BodyPanel(bytes: publish?.payload ?? [], contentType: nil, emptyText: "Empty payload")
            case .details:
                KeyValueList(rows: MQTTDescriber.rows(for: event).map { ($0.label, $0.value) }, nameWidth: 120, monospacedValues: false)
            case .hex:
                CodeText(text: Formatting.hexDump(event.frame.rawBytes))
            }
        }
    }
}

// MARK: WebSocket

struct WebSocketInspector: View {
    let message: WebSocketMessage
    @State private var tab: Tab = .payload

    enum Tab: Hashable { case payload, hex }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TypePill(text: "\(message.opcode)".uppercased(), color: Theme.webSocket, fixedWidth: nil)
                    Text(message.direction == .clientToServer ? "client → server" : "server → client")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Formatting.compactByteCount(message.payload.count))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                URLText(url: message.url)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            InspectorTabs(tabs: [(Tab.payload, "Payload", nil), (.hex, "Hex", nil)], selection: $tab, trailing: nil)
            switch tab {
            case .payload:
                BodyPanel(bytes: message.payload, contentType: message.opcode == .binary ? "application/octet-stream" : nil,
                          emptyText: "Empty message")
            case .hex:
                CodeText(text: Formatting.hexDump(message.payload))
            }
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
