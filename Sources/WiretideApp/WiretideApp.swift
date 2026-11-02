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
            WiretideApp.main()
        }
    }
}

struct WiretideApp: App {
    @State private var setup = AppSetup.load()
    @StateObject private var updates = Updates()

    init() {
        // Lets `swift run Wiretide` show a normal app with a Dock icon and menu bar.
        // (A packaged .app gets this from its Info.plist; setting it again is harmless.)
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("Wiretide") {
            switch setup {
            case .ready(let model, let storage, let license, _):
                ContentView(model: model, certificates: storage, license: license)
                    .frame(minWidth: 1000, minHeight: 600)
                    .onAppear { updates.follow(license) }
                    .onChange(of: license.entitlement) { updates.follow(license) }
            case .failed(let message):
                ContentUnavailableView("Wiretide could not start", systemImage: "xmark.octagon", description: Text(message))
                    .frame(minWidth: 500, minHeight: 300)
            }
        }
        // The toolbar carries the recording control and the filter field; the window title would only crowd it.
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            UpdateCommands(updates: updates)
            CaptureCommands(model: setup.model)
            RowDensityCommands()
        }

        Window("Map & Rewrite", id: RulesWindow.id) {
            if let model = setup.model {
                RulesWindow(model: model)
            }
        }
        .windowResizability(.contentMinSize)

        Window("Saved Sessions", id: SessionsWindow.id) {
            if case .ready(let model, _, let license, _) = setup {
                SessionsWindow(model: model, license: license)
            }
        }
        .windowResizability(.contentMinSize)

        Window("Scripts", id: ScriptsWindow.id) {
            if let model = setup.model {
                ScriptsWindow(model: model)
            }
        }
        .windowResizability(.contentMinSize)

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
    private static let rewriteRulesKey = "rewriteRules"
    private static let scriptsKey = "userScripts"

    var model: CaptureViewModel? {
        if case .ready(let model, _, _, _) = self { model } else { nil }
    }

    @MainActor
    static func load() -> AppSetup {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Wiretide", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

            let storage = CertificateStorage(directory: support)
            let authority = try storage.loadOrCreate()
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let store = try CaptureStore(path: support.appendingPathComponent("captures.sqlite").path,
                                         sessionName: formatter.string(from: Date()))
            // Every launch starts a session; drop earlier ones that never recorded anything.
            try? store.deleteEmptySessions()

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
            let rewriteSettings = defaults.data(forKey: rewriteRulesKey).flatMap { try? JSONDecoder().decode(RewriteSettings.self, from: $0) }
                ?? RewriteSettings()
            let rewrites = RewriteCenter(settings: rewriteSettings) { settings in
                if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: rewriteRulesKey) }
            }
            let scriptSettings = defaults.data(forKey: scriptsKey).flatMap { try? JSONDecoder().decode(ScriptSettings.self, from: $0) }
                ?? ScriptSettings()
            let scripts = ScriptCenter(settings: scriptSettings) { settings in
                if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: scriptsKey) }
            }
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
                composer: composer,
                rewrites: rewrites,
                scripts: scripts
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

/// View › Regular Rows / Compact Rows.
struct RowDensityCommands: Commands {
    @AppStorage(RowDensity.storageKey) private var density = RowDensity.regular

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Picker("Row Height", selection: $density) {
                ForEach(RowDensity.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
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

            Button("New Session") { model?.requestNewSession(named: SessionNames.now()) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model == nil)

            Button("Saved Sessions…") { model?.sessionsPresented = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model == nil)

            Button("Back to Live Capture") { model?.returnToLive() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model?.viewedSession == nil)

            Divider()

            Button(model?.breakpoints.isEnabled == true ? "Turn Breakpoints Off" : "Turn Breakpoints On") {
                model?.breakpoints.isEnabled.toggle()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(model == nil)

            Button("Map & Rewrite Rules…") { model?.rewrites.isPresented = true }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(model == nil)

            Button(model?.rewrites.isEnabled == true ? "Turn Map & Rewrite Off" : "Turn Map & Rewrite On") {
                model?.rewrites.isEnabled.toggle()
            }
            .disabled(model == nil)

            Button("Scripts…") { model?.scripts.isPresented = true }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(model == nil)

            Button(model?.scripts.isEnabled == true ? "Turn Scripts Off" : "Turn Scripts On") {
                model?.scripts.isEnabled.toggle()
            }
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
