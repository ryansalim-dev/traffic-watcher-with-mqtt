#if os(macOS)
import AppCore
import MQTTCore
import ProxyCore
import SwiftUI

/// The Publish sheet: send a new MQTT message, or replay a captured one, to any broker.
struct MQTTComposerView: View {
    @Bindable var composer: MQTTComposer
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                settings
                    .frame(width: 330)
                Divider()
                payloadEditor
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 880, minHeight: 560, idealHeight: 620)
        .tint(Theme.accent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(Theme.mqtt)
                    .frame(width: 28, height: 28)
                    .background(Theme.mqtt.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(composer.topic.isEmpty ? "Publish Message" : "Publish to \(composer.topic)")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                HStack(spacing: 6) {
                    StatusDot(color: composer.target.host.isEmpty ? Theme.neutral : Theme.success)
                    Text("\(composer.target.host.isEmpty ? "No broker" : composer.target.host):\(String(composer.target.port)) · MQTT \(composer.target.version == .v5 ? "5.0" : "3.1.1")\(composer.target.useTLS ? " · TLS" : "")")
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Theme.fill, in: Capsule())
            }
            if !composer.isAllowed {
                ProNotice(feature: "MQTT publish and replay", detail: "You can fill this in now; sending needs a Pro license.")
            }
        }
        .padding(16)
    }

    private var settings: some View {
        Form {
            Section("Message") {
                TextField("Topic", text: $composer.topic, prompt: Text("home/kitchen/light/set"))
                    .font(.body.monospaced())
                Picker("QoS", selection: $composer.qos) {
                    Text("0").tag(MQTTQoS.atMostOnce)
                    Text("1").tag(MQTTQoS.atLeastOnce)
                    Text("2").tag(MQTTQoS.exactlyOnce)
                }
                .pickerStyle(.segmented)
                .help("0: at most once · 1: at least once · 2: exactly once")
                Toggle("Retain", isOn: $composer.retain)
                if composer.target.version == .v5 {
                    TextField("Content type", text: $composer.contentType, prompt: Text("application/json"))
                    ForEach(composer.userProperties.indices, id: \.self) { index in
                        HStack {
                            TextField("Key", text: $composer.userProperties[index].key, prompt: Text("Key")).labelsHidden()
                            TextField("Value", text: $composer.userProperties[index].value, prompt: Text("Value")).labelsHidden()
                            Button {
                                composer.userProperties.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Add User Property") { composer.userProperties.append(.init(key: "", value: "")) }
                }
            }
            Section("Broker") {
                TextField("Host", text: $composer.target.host, prompt: Text("broker.example.com"))
                TextField("Port", value: $composer.target.port, format: .number.grouping(.never), prompt: Text("1883"))
                Picker("Version", selection: $composer.target.version) {
                    Text("3.1.1").tag(MQTTVersion.v3_1_1)
                    Text("5.0").tag(MQTTVersion.v5)
                }
                .pickerStyle(.segmented)
                Toggle("TLS", isOn: $composer.target.useTLS)
                if composer.target.useTLS {
                    Toggle("Verify certificate", isOn: $composer.target.verifyCertificate)
                }
                TextField("Client ID", text: $composer.target.clientIdentifier, prompt: Text("Generated"))
                TextField("User name", text: optional(\.username), prompt: Text("None"))
                SecureField("Password", text: optional(\.password), prompt: Text("None"))
            }
        }
        .formStyle(.grouped)
    }

    private var payloadEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                CapsLabel("Payload")
                Spacer()
                if let payload = composer.payload {
                    Text(payloadSummary(payload))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Picker("Format", selection: $composer.payloadFormat) {
                    ForEach(MQTTComposer.PayloadFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            TextEditor(text: $composer.payloadText)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("Send")
                TextField("Times", value: $composer.repeatCount, format: .number)
                    .labelsHidden()
                    .frame(width: 52)
                    .multilineTextAlignment(.trailing)
                Text(composer.repeatCount == 1 ? "time" : "times, every")
                if composer.repeatCount > 1 {
                    TextField("Interval", value: $composer.intervalMilliseconds, format: .number)
                        .labelsHidden()
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                    Text("ms")
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            Divider().frame(height: 16)
            statusLine
            Spacer()
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
            if composer.isSending {
                Button("Stop") { composer.cancel() }
            } else {
                Button {
                    composer.send()
                } label: {
                    Label(composer.repeatCount > 1 ? "Send \(composer.repeatCount)×" : "Send", systemImage: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(composer.problem != nil)
                .help(composer.problem ?? "Connect, publish, then disconnect (⌘↩)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func payloadSummary(_ payload: [UInt8]) -> String {
        let size = Formatting.byteCount(payload.count)
        guard composer.payloadFormat != .hex, !payload.isEmpty else { return size }
        return Formatting.prettyJSON(payload) != nil ? "\(size) · valid JSON" : size
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

    private func optional(_ keyPath: WritableKeyPath<MQTTBrokerTarget, String?>) -> Binding<String> {
        Binding(get: { composer.target[keyPath: keyPath] ?? "" },
                set: { composer.target[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }
}
#endif
