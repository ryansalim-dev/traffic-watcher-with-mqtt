#if os(macOS)
import AppCore
import AppKit
import CaptureStore
import Licensing
import ProxyCore
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
enum Launcher {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--screenshots"), index + 1 < arguments.count {
            Screenshots.run(into: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        } else {
            TrafficWatcherApp.main()
        }
    }
}

struct TrafficWatcherApp: App {
    @State private var setup = AppSetup.load()
    @StateObject private var updates = Updates()

    init() {
        // Lets `swift run TrafficWatcher` show a normal app with a Dock icon and menu bar.
        // (A packaged .app gets this from its Info.plist; setting it again is harmless.)
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("Traffic Watcher") {
            switch setup {
            case .ready(let model, let storage, let license, _):
                ContentView(model: model, certificates: storage, license: license)
                    .frame(minWidth: 1000, minHeight: 600)
            case .failed(let message):
                ContentUnavailableView("Traffic Watcher could not start", systemImage: "xmark.octagon", description: Text(message))
                    .frame(minWidth: 500, minHeight: 300)
            }
        }
        .commands {
            UpdateCommands(updates: updates)
            CaptureCommands(model: setup.model)
        }

        Settings {
            if case .ready(let model, let storage, let license, let helper) = setup {
                SettingsView(model: model, certificates: storage, license: license, helper: helper)
            }
        }
    }
}

/// Builds the store, certificate authority and engine from the Application Support folder.
enum AppSetup {
    case ready(CaptureViewModel, CertificateStorage, LicenseManager, SystemProxyHelper)
    case failed(String)

    private static let configurationKey = "engineConfiguration"
    private static let breakpointRulesKey = "breakpointRules"
    private static let publishTargetKey = "publishTarget"

    var model: CaptureViewModel? {
        if case .ready(let model, _, _, _) = self { model } else { nil }
    }

    @MainActor
    static func load() -> AppSetup {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("TrafficWatcher", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

            let storage = CertificateStorage(directory: support)
            let authority = try storage.loadOrCreate()
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let store = try CaptureStore(path: support.appendingPathComponent("captures.sqlite").path,
                                         sessionName: formatter.string(from: Date()))

            var configuration = EngineConfiguration()
            if let data = UserDefaults.standard.data(forKey: configurationKey),
               let saved = try? JSONDecoder().decode(EngineConfiguration.self, from: data) {
                configuration = saved
            }
            let defaults = UserDefaults.standard
            let rules = defaults.data(forKey: breakpointRulesKey).flatMap { try? JSONDecoder().decode([BreakpointRule].self, from: $0) } ?? []
            let breakpoints = BreakpointCenter(rules: rules) { rules in
                if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: breakpointRulesKey) }
            }
            let engine = CaptureEngine(authority: authority)
            let publishTarget = defaults.data(forKey: publishTargetKey).flatMap { try? JSONDecoder().decode(MQTTBrokerTarget.self, from: $0) }
                ?? MQTTBrokerTarget(host: configuration.forwarders.first?.brokerHost ?? "localhost",
                                    port: configuration.forwarders.first?.brokerPort,
                                    useTLS: configuration.forwarders.first?.useTLS ?? false)
            let composer = MQTTComposer(publisher: engine.makePublisher(), target: publishTarget) { target in
                // The password stays in memory only.
                var saved = target
                saved.password = nil
                if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: publishTargetKey) }
            }
            let model = CaptureViewModel(
                store: store,
                engine: engine,
                configuration: configuration,
                systemProxy: HelperConnection(),
                saveConfiguration: { configuration in
                    if let data = try? JSONEncoder().encode(configuration) {
                        UserDefaults.standard.set(data, forKey: configurationKey)
                    }
                },
                breakpoints: breakpoints,
                composer: composer
            )
            let license = LicenseManager(
                configuration: LicenseConfiguration(infoDictionary: Bundle.main.infoDictionary ?? [:]),
                storage: KeychainLicenseStorage()
            )
            return .ready(model, storage, license, SystemProxyHelper())
        } catch {
            return .failed(String(describing: error))
        }
    }
}

struct CaptureCommands: Commands {
    let model: CaptureViewModel?

    var body: some Commands {
        CommandMenu("Capture") {
            Button(model?.isCapturing == true ? "Stop Capture" : "Start Capture") {
                guard let model else { return }
                Task {
                    if model.isCapturing {
                        await model.stopCapture()
                    } else {
                        await model.startCapture()
                    }
                }
            }
            .keyboardShortcut("r")
            .disabled(model == nil)

            Button("New Session") { model?.newSession() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model == nil)

            Divider()

            Button(model?.breakpoints.isEnabled == true ? "Turn Breakpoints Off" : "Turn Breakpoints On") {
                model?.breakpoints.isEnabled.toggle()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(model == nil)

            Button("Publish MQTT Message…") { model?.composer.isPresented = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model == nil)

            Divider()

            Button("Export HTTP as HAR…") {
                guard let model else { return }
                save(name: "capture.har", type: .json) { try model.exportHAR() }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model == nil)

            Button("Export MQTT as JSON Lines…") {
                guard let model else { return }
                save(name: "mqtt.jsonl", type: .plainText) { try model.exportMQTT() }
            }
            .disabled(model == nil)
        }
    }

    @MainActor
    private func save(name: String, type: UTType, data: () throws -> Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data().write(to: url)
        } catch {
            _ = NSAlert(error: error).runModal()
        }
    }
}
#endif
