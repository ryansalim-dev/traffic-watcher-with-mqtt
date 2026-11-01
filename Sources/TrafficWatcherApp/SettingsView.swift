#if os(macOS)
import AppCore
import AppKit
import SwiftUI
import TLSMitm

struct SettingsView: View {
    @Bindable var model: CaptureViewModel
    let certificates: CertificateStorage
    let license: LicenseManager
    let helper: SystemProxyHelper
    @State var tab: Tab = .proxy

    enum Tab: Hashable { case proxy, mqtt, certificate, license }

    var body: some View {
        TabView(selection: $tab) {
            ProxySettings(model: model, helper: helper)
                .tabItem { Label("Proxy", systemImage: "network") }
                .tag(Tab.proxy)
            MQTTSettings(model: model)
                .tabItem { Label("MQTT", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(Tab.mqtt)
            CertificateSettings(model: model, certificates: certificates)
                .tabItem { Label("Certificate", systemImage: "checkmark.seal") }
                .tag(Tab.certificate)
            LicenseSettings(license: license)
                .tabItem { Label("License", systemImage: "key") }
                .tag(Tab.license)
        }
        .frame(width: 560, height: 520)
    }
}

private struct RestartHint: View {
    let model: CaptureViewModel

    var body: some View {
        if model.isCapturing, model.configuration != model.runningConfiguration {
            Label("Restart capture to apply changes.", systemImage: "arrow.clockwise")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }
}

struct ProxySettings: View {
    @Bindable var model: CaptureViewModel
    let helper: SystemProxyHelper
    @State private var newBypassHost = ""
    @State private var selectedBypass: String?

    var body: some View {
        Form {
            Section {
                TextField("Port", value: $model.configuration.proxyPort, format: .number.grouping(.never))
                Toggle("Allow other devices on this network", isOn: $model.configuration.allowRemoteDevices)
                Toggle("Decrypt HTTPS", isOn: $model.configuration.decryptHTTPS)
            } footer: {
                Text("Set the HTTP proxy of your Mac, Simulator or iPhone to this Mac's address and port. Other devices need the first toggle on.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use as this Mac's proxy while capturing", isOn: $model.configuration.setSystemProxy)
                    .disabled(helper.state != .installed)
                HStack {
                    helperStatus
                    Spacer()
                    switch helper.state {
                    case .notInstalled, .failed: Button("Install Helper…") { helper.install() }
                    case .needsApproval: Button("Open Login Items…") { helper.openLoginItems() }
                    case .installed: Button("Uninstall") { helper.uninstall() }
                    case .unavailable: EmptyView()
                    }
                }
            } header: {
                Text("System proxy")
            } footer: {
                Text("Mac apps and the Simulator then go through Traffic Watcher without any setup. A small helper changes the network settings and puts your previous proxy settings back when capture stops, the app quits or the Mac restarts.")
                    .foregroundStyle(.secondary)
            }

            Section("Never decrypt") {
                List(selection: $selectedBypass) {
                    ForEach(model.configuration.bypassHosts, id: \.self) { Text($0) }
                }
                .frame(minHeight: 80)
                HStack {
                    TextField("Host, or *.example.com", text: $newBypassHost)
                        .onSubmit(addBypass)
                    Button("Add", action: addBypass).disabled(newBypassHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove") {
                        model.configuration.bypassHosts.removeAll { $0 == selectedBypass }
                        selectedBypass = nil
                    }
                    .disabled(selectedBypass == nil)
                }
            }
            RestartHint(model: model)
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in helper.refresh() }
    }

    @ViewBuilder private var helperStatus: some View {
        switch helper.state {
        case .installed:
            Label("Helper installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .needsApproval:
            Label("Allow “Traffic Watcher” in Login Items to finish", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        case .notInstalled:
            Label("Helper not installed", systemImage: "circle.dashed").foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
        case .unavailable:
            Label("Available in the downloaded app", systemImage: "info.circle").foregroundStyle(.secondary)
        }
    }

    private func addBypass() {
        let host = newBypassHost.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty, !model.configuration.bypassHosts.contains(host) else { return }
        model.configuration.bypassHosts.append(host)
        newBypassHost = ""
    }
}

struct MQTTSettings: View {
    @Bindable var model: CaptureViewModel
    @State private var selection: ForwarderConfiguration.ID?

    var body: some View {
        Form {
            Section {
                Table(model.configuration.forwarders, selection: $selection) {
                    TableColumn("Broker host") { forwarder in
                        TextField("broker.example.com", text: binding(forwarder.id).brokerHost).labelsHidden()
                    }
                    TableColumn("Port") { forwarder in
                        TextField("1883", value: binding(forwarder.id).brokerPort, format: .number.grouping(.never)).labelsHidden()
                    }
                    .width(60)
                    TableColumn("TLS") { forwarder in
                        Toggle("TLS", isOn: binding(forwarder.id).useTLS).labelsHidden()
                    }
                    .width(36)
                    TableColumn("Local port") { forwarder in
                        TextField("18830", value: binding(forwarder.id).listenPort, format: .number.grouping(.never)).labelsHidden()
                    }
                    .width(76)
                }
                .frame(minHeight: 140)
                HStack {
                    Button {
                        let used = Set(model.configuration.forwarders.map(\.listenPort))
                        let port = (18830...18899).first { !used.contains($0) } ?? 18830
                        let forwarder = ForwarderConfiguration(brokerHost: "", listenPort: port)
                        model.configuration.forwarders.append(forwarder)
                        selection = forwarder.id
                    } label: {
                        Image(systemName: "plus")
                    }
                    Button {
                        model.configuration.forwarders.removeAll { $0.id == selection }
                        selection = nil
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Brokers")
            } footer: {
                Text("Point your app at localhost and the local port instead of the broker. Traffic Watcher relays every packet to the broker and logs it, over plain TCP or TLS. MQTT over WebSockets is captured through the HTTP proxy automatically.")
                    .foregroundStyle(.secondary)
            }
            RestartHint(model: model)
        }
        .formStyle(.grouped)
    }

    /// A binding to one forwarder by id, so edits survive rows being added or removed.
    private func binding(_ id: ForwarderConfiguration.ID) -> Binding<ForwarderConfiguration> {
        Binding(
            get: { model.configuration.forwarders.first { $0.id == id } ?? ForwarderConfiguration(brokerHost: "") },
            set: { updated in
                if let index = model.configuration.forwarders.firstIndex(where: { $0.id == id }) {
                    model.configuration.forwarders[index] = updated
                }
            }
        )
    }
}

struct CertificateSettings: View {
    let model: CaptureViewModel
    let certificates: CertificateStorage
    @State private var status: String?
    @State private var failed = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Root certificate", value: "Traffic Watcher CA")
                LabeledContent("Stored in") {
                    Text(certificates.directory.path(percentEncoded: false))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } footer: {
                Text("The certificate and its private key are created on this Mac on first launch and never leave it. Anyone with the key could read traffic from devices that trust it.")
                    .foregroundStyle(.secondary)
            }

            Section("Trust it") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("iOS Simulator")
                        Text("Adds the root to the booted Simulator.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Install") { run { try installInSimulator() } }
                }
                HStack {
                    VStack(alignment: .leading) {
                        Text("iPhone or iPad")
                        Text("AirDrop the .cer, install the profile, then enable full trust in Settings › General › About › Certificate Trust Settings.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show in Finder") { run { try revealDER() } }
                }
            }

            if let status {
                Label(status, systemImage: failed ? "xmark.octagon" : "checkmark.circle")
                    .foregroundStyle(failed ? .red : .green)
            }
        }
        .formStyle(.grouped)
    }

    private func run(_ action: () throws -> String) {
        do {
            status = try action()
            failed = false
        } catch {
            status = String(describing: error)
            failed = true
        }
    }

    private func derURL() throws -> URL {
        guard let authority = model.authority else { throw CocoaError(.fileNoSuchFile) }
        return try certificates.exportDER(authority)
    }

    private func installInSimulator() throws -> String {
        _ = try SimulatorTools.installRootCertificate(at: try derURL())
        return "Installed in the booted Simulator. Restart the app you're inspecting."
    }

    private func revealDER() throws -> String {
        let url = try derURL()
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return "Saved \(url.lastPathComponent)."
    }
}
#endif
