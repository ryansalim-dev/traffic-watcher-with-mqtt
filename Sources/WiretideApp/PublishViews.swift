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
            Form {
                if !composer.isAllowed {
                    ProNotice(feature: "MQTT publish and replay", detail: "You can fill this in now; sending needs a Pro license.")
                }
                Section("Broker") {
                    HStack {
                        TextField("Host", text: $composer.target.host, prompt: Text("broker.example.com"))
                        TextField("Port", value: $composer.target.port, format: .number.grouping(.never))
                            .frame(width: 110)
                    }
                    Picker("MQTT version", selection: $composer.target.version) {
                        Text("3.1.1").tag(MQTTVersion.v3_1_1)
                        Text("5.0").tag(MQTTVersion.v5)
                    }
                    .pickerStyle(.segmented)
                    Toggle("TLS", isOn: $composer.target.useTLS)
                    if composer.target.useTLS {
                        Toggle("Verify the broker's certificate", isOn: $composer.target.verifyCertificate)
                    }
                    TextField("Client ID", text: $composer.target.clientIdentifier, prompt: Text("Generated"))
                    TextField("User name", text: optional(\.username), prompt: Text("None"))
                    SecureField("Password", text: optional(\.password), prompt: Text("None"))
                }
                Section("Message") {
                    TextField("Topic", text: $composer.topic, prompt: Text("home/kitchen/light/set"))
                        .font(.body.monospaced())
                    Picker("QoS", selection: $composer.qos) {
                        Text("0 · at most once").tag(MQTTQoS.atMostOnce)
                        Text("1 · at least once").tag(MQTTQoS.atLeastOnce)
                        Text("2 · exactly once").tag(MQTTQoS.exactlyOnce)
                    }
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
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Payload")
                            Spacer()
                            if let payload = composer.payload {
                                Text(Formatting.byteCount(payload.count)).font(.caption).foregroundStyle(.secondary)
                            }
                            Picker("Format", selection: $composer.payloadFormat) {
                                ForEach(MQTTComposer.PayloadFormat.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 120)
                        }
                        TextEditor(text: $composer.payloadText)
                            .font(.callout.monospaced())
                            .frame(minHeight: 110)
                            .border(Color(nsColor: .separatorColor))
                    }
                }
                Section {
                    Stepper(value: $composer.repeatCount, in: 1...10_000) {
                        HStack {
                            Text("Send")
                            TextField("Times", value: $composer.repeatCount, format: .number)
                                .labelsHidden()
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                            Text(composer.repeatCount == 1 ? "time" : "times")
                        }
                    }
                    if composer.repeatCount > 1 {
                        HStack {
                            Text("Wait between messages")
                            Spacer()
                            TextField("Interval", value: $composer.intervalMilliseconds, format: .number)
                                .labelsHidden()
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                            Text("ms")
                        }
                    }
                } header: {
                    Text("Repeat")
                } footer: {
                    Text("Everything sent here also appears in the MQTT timeline.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 10) {
                statusLine
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                if composer.isSending {
                    Button("Stop") { composer.cancel() }
                } else {
                    Button("Send") { composer.send() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(composer.problem != nil)
                        .help(composer.problem ?? "Connect, publish, then disconnect (⌘↩)")
                }
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 640, idealHeight: 720)
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
