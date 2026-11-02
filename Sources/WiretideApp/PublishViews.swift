#if os(macOS)
import AppCore
import MQTTCore
import ProxyCore
import SwiftUI

/// The Publish sheet: send a new MQTT message, or replay a captured one, to any broker.
/// Two panes as in the mockup: message settings on the left, the payload editor on the right.
struct MQTTComposerView: View {
    @Bindable var composer: MQTTComposer
    var suggestions: [String] = []
    var onClose: () -> Void = {}
    @State private var showsConnection = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                settings
                    .frame(width: 280)
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }
                payloadEditor
            }
            footer
        }
        .frame(minWidth: 740, idealWidth: 760, minHeight: 500, idealHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Theme.accent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(composer.replayedAt == nil ? "Publish message" : "Replay message")
                    .font(.system(size: 14, weight: .semibold))
                if let replayedAt = composer.replayedAt {
                    Text("from \(replayedAt.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showsConnection = true
                } label: {
                    HStack(spacing: 7) {
                        StatusDot(color: composer.target.host.isEmpty ? Theme.neutral : Theme.success, halo: !composer.target.host.isEmpty)
                        Text(connectionTitle)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.fill, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Change the broker")
                .popover(isPresented: $showsConnection, arrowEdge: .bottom) {
                    BrokerSettingsForm(target: $composer.target)
                }
            }
            if !composer.isAllowed {
                ProNotice(feature: "MQTT publish and replay", detail: "You can fill this in now; sending needs a Pro license.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var connectionTitle: String {
        let host = composer.target.host.isEmpty ? "No broker" : composer.target.host
        return "\(host):\(String(composer.target.port)) · MQTT \(composer.target.version == .v5 ? "5.0" : "3.1.1")\(composer.target.useTLS ? " · TLS" : "")"
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FieldGroup(label: "Topic") {
                    BoxedTextField(title: "Topic", text: $composer.topic, prompt: "home/kitchen/light/set", monospaced: true)
                    let others = suggestions.filter { $0 != composer.topic }.prefix(3)
                    if !others.isEmpty {
                        FlowLayout(spacing: 5, lineSpacing: 5) {
                            ForEach(Array(others), id: \.self) { topic in
                                Button(topic) { composer.topic = topic }
                                    .buttonStyle(SuggestionButtonStyle())
                            }
                        }
                    }
                }
                FieldGroup(label: "QoS") {
                    PillSegments(options: [(MQTTQoS.atMostOnce, "0"), (.atLeastOnce, "1"), (.exactlyOnce, "2")],
                                 selection: $composer.qos)
                        .help("0: at most once · 1: at least once · 2: exactly once")
                }
                HStack {
                    Text("Retain").font(.system(size: 12.5))
                    Spacer()
                    Toggle("Retain", isOn: $composer.retain)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                if composer.target.version == .v5 {
                    FieldGroup(label: "Properties") {
                        PropertyRow(key: .constant("content-type"), value: $composer.contentType, fixedKey: true, prompt: "none")
                        ForEach(composer.userProperties.indices, id: \.self) { index in
                            PropertyRow(key: $composer.userProperties[index].key, value: $composer.userProperties[index].value,
                                        prompt: "value") {
                                composer.userProperties.remove(at: index)
                            }
                        }
                        Button {
                            composer.userProperties.append(.init(key: "", value: ""))
                        } label: {
                            Label("Add property", systemImage: "plus")
                        }
                        .buttonStyle(MiniButtonStyle())
                    }
                }
                HStack {
                    Text("Connection")
                    Spacer()
                    Button(connectionSummary) { showsConnection = true }
                        .buttonStyle(.plain)
                        .help("Change the broker, client ID and credentials")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private var connectionSummary: String {
        let client = composer.target.clientIdentifier.isEmpty ? "Client ID generated" : "Client ID \(composer.target.clientIdentifier)"
        let auth = composer.target.username == nil ? "no auth" : "user \(composer.target.username ?? "")"
        return "\(client) · \(auth)"
    }

    private var payloadEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PillSegments(options: MQTTComposer.PayloadFormat.allCases.map { ($0, $0.rawValue) },
                             selection: $composer.payloadFormat)
                    .frame(width: 190)
                Spacer()
                if let payload = composer.payload {
                    Text(payloadSummary(payload))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                } else {
                    Text("Not valid hex").font(.system(size: 12)).foregroundStyle(Theme.failure)
                }
                Button("Format") { composer.formatPayload() }
                    .buttonStyle(ChipButtonStyle())
                    .disabled(!composer.payloadIsValidJSON)
                    .help("Pretty-print the JSON")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            CodeEditor(text: $composer.payloadText, highlightJSON: composer.payloadFormat == .json)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("Send")
                TextField("Times", value: $composer.repeatCount, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .frame(width: 34)
                    .boxed()
                    .frame(height: 24)
                Text(composer.repeatCount == 1 ? "time" : "times, every")
                if composer.repeatCount > 1 {
                    HStack(spacing: 3) {
                        TextField("Interval", value: $composer.intervalMilliseconds, format: .number)
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 34)
                        Text("ms").foregroundStyle(.secondary)
                    }
                    .boxed()
                    .frame(height: 24)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            statusLine
                .font(.system(size: 12))
            Spacer()
            Text("Esc to close").font(.system(size: 12)).foregroundStyle(.tertiary)
            Button("Cancel", action: onClose)
                .buttonStyle(ChipButtonStyle())
                .keyboardShortcut(.cancelAction)
            if composer.isSending {
                Button("Stop") { composer.cancel() }
                    .buttonStyle(ChipButtonStyle())
            } else {
                Button {
                    composer.send()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane.fill").font(.system(size: 11))
                        Text(composer.repeatCount > 1 ? "Send \(composer.repeatCount)×" : "Send")
                        Text("⌘↩").opacity(0.7)
                    }
                }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(composer.problem != nil)
                .opacity(composer.problem != nil ? 0.5 : 1)
                .help(composer.problem ?? "Connect, publish, then disconnect (⌘↩)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func payloadSummary(_ payload: [UInt8]) -> String {
        let size = "\(payload.count.formatted()) byte\(payload.count == 1 ? "" : "s")"
        guard composer.payloadFormat != .hex, !payload.isEmpty else { return size }
        if Formatting.prettyJSON(payload) != nil { return "\(size) · valid JSON" }
        return composer.payloadFormat == .json ? "\(size) · not valid JSON" : size
    }

    @ViewBuilder
    private var statusLine: some View {
        if composer.isSending {
            ProgressView().controlSize(.small)
            Text("Sent \(composer.sentCount) of \(composer.repeatCount)…").foregroundStyle(.secondary)
        } else if let status = composer.status {
            switch status {
            case .sent(let count, let to):
                Label("Sent \(count == 1 ? "1 message" : "\(count) messages") to \(to)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .partlyRefused(let accepted, let refused, let reason):
                Label("\(accepted) accepted, \(refused) refused (reason 0x\(String(reason, radix: 16, uppercase: true)))",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        } else if let problem = composer.problem, composer.isAllowed {
            Text(problem).foregroundStyle(.secondary)
        }
    }

}

/// Broker, version, TLS and credentials, in a popover from the sheet's connection capsule.
struct BrokerSettingsForm: View {
    @Binding var target: MQTTBrokerTarget

    var body: some View {
        Form {
            TextField("Host", text: $target.host, prompt: Text("broker.example.com"))
            TextField("Port", value: $target.port, format: .number.grouping(.never), prompt: Text("1883"))
            Picker("Version", selection: $target.version) {
                Text("3.1.1").tag(MQTTVersion.v3_1_1)
                Text("5.0").tag(MQTTVersion.v5)
            }
            .pickerStyle(.segmented)
            Toggle("TLS", isOn: $target.useTLS)
            if target.useTLS {
                Toggle("Verify certificate", isOn: $target.verifyCertificate)
            }
            TextField("Client ID", text: $target.clientIdentifier, prompt: Text("Generated"))
            TextField("User name", text: optional(\.username), prompt: Text("None"))
            SecureField("Password", text: optional(\.password), prompt: Text("None"))
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func optional(_ keyPath: WritableKeyPath<MQTTBrokerTarget, String?>) -> Binding<String> {
        Binding(get: { target[keyPath: keyPath] ?? "" },
                set: { target[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }
}

/// One MQTT 5 property: name and value in a quiet box, as in the mockup.
struct PropertyRow: View {
    @Binding var key: String
    @Binding var value: String
    var fixedKey = false
    var prompt = ""
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if fixedKey {
                Text(key).font(.system(size: 12, design: .monospaced))
            } else {
                TextField("Name", text: $key, prompt: Text("name"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: 100)
            }
            TextField("Value", text: $value, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove this property")
            }
        }
        .boxed()
    }
}

/// A topic suggestion under the Topic field.
struct SuggestionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
#endif
