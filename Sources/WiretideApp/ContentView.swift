#if os(macOS)
import AppCore
import AppKit
import MQTTCore
import ProxyCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: CaptureViewModel
    let certificates: CertificateStorage
    let license: LicenseManager
    @State var mqttMode = MQTTMode.packets
    @State var selectedTopic: TopicNode.ID?
    @State var showInspector = true

    enum MQTTMode: String, CaseIterable, Identifiable {
        case packets = "Packets", topics = "Topics"
        var id: String { rawValue }
    }

    private var showsTopics: Bool { model.section == .mqtt && mqttMode == .topics }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            Group {
                if showsTopics {
                    TopicTreeView(tree: model.topicTree, selection: $selectedTopic)
                } else {
                    TrafficTimeline(model: model)
                }
            }
            .frame(minWidth: 420)
            .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search URLs, headers, bodies, topics, payloads")
            .toolbar {
                if model.section == .mqtt {
                    ToolbarItem(placement: .principal) {
                        Picker("View", selection: $mqttMode) {
                            ForEach(MQTTMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            .inspector(isPresented: $showInspector) {
                Group {
                    if showsTopics {
                        TopicDetailView(tree: model.topicTree, topic: selectedTopic) { topic in
                            model.preparePublish(toTopic: topic)
                            model.composer.isPresented = true
                        }
                    } else {
                        InspectorView(model: model)
                    }
                }
                .inspectorColumnWidth(min: 320, ideal: 460, max: 800)
                .toolbar {
                    ToolbarItem {
                        Button {
                            showInspector.toggle()
                        } label: {
                            Label("Inspector", systemImage: "sidebar.trailing")
                        }
                        .help("Show or hide the inspector (⌥⌘I)")
                        .keyboardShortcut("i", modifiers: [.command, .option])
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                CaptureToggle(model: model)
            }
            ToolbarItem(placement: .primaryAction) {
                BreakpointsToggle(center: model.breakpoints)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.composer.isPresented = true
                } label: {
                    Label("Publish", systemImage: "paperplane")
                }
                .help("Publish an MQTT message (⇧⌘P)")
            }
        }
        .sheet(isPresented: Binding(get: { model.composer.isPresented }, set: { model.composer.isPresented = $0 })) {
            MQTTComposerView(composer: model.composer) { model.composer.isPresented = false }
        }
        .sheet(item: Binding(get: { model.breakpoints.paused.first }, set: { _ in })) { item in
            BreakpointEditor(center: model.breakpoints, item: item)
                .id(item.id)
        }
        .safeAreaInset(edge: .bottom) {
            StatusBar(model: model, license: license)
        }
        .task {
            model.sessionLimit = license.sessionLimit
            model.apply(license.entitlement)
            await license.refreshIfNeeded()
        }
        .onChange(of: license.entitlement) {
            model.sessionLimit = license.sessionLimit
            model.apply(license.entitlement)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await license.refreshIfNeeded() }
        }
        .alert("Something went wrong", isPresented: .constant(model.lastError != nil)) {
            Button("OK") {}
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

struct CaptureToggle: View {
    let model: CaptureViewModel

    var body: some View {
        Button {
            Task {
                if model.isCapturing {
                    await model.stopCapture()
                } else {
                    await model.startCapture()
                }
            }
        } label: {
            Label(model.isCapturing ? "Stop" : "Start",
                  systemImage: model.isCapturing ? "stop.circle.fill" : "record.circle")
        }
        .tint(model.isCapturing ? .red : .accentColor)
        .help(model.isCapturing ? "Stop capturing (⌘R)" : "Start the proxy and MQTT forwarders (⌘R)")
    }
}

struct StatusBar: View {
    let model: CaptureViewModel
    let license: LicenseManager

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(model.isCapturing ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            if let port = model.proxyPort {
                Text("HTTP proxy on \(model.configuration.allowRemoteDevices ? "all interfaces" : "127.0.0.1"):\(String(port))")
            } else {
                Text("Not capturing")
            }
            ForEach(model.isCapturing ? model.configuration.forwarders : []) { forwarder in
                Text("MQTT :\(String(forwarder.listenPort)) → \(forwarder.label)")
            }
            Spacer()
            if !model.breakpoints.paused.isEmpty {
                Label("\(model.breakpoints.paused.count) paused", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
            }
            Text("\(model.rows.count) events")
            SettingsLink {
                Text(license.entitlement.isPro ? "PRO" : "FREE")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background((license.entitlement.isPro ? Color.accentColor : Color.secondary).opacity(0.15), in: Capsule())
                    .foregroundStyle(license.entitlement.isPro ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(license.summary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct SidebarView: View {
    @Bindable var model: CaptureViewModel

    var body: some View {
        List(selection: Binding(get: { model.section }, set: { model.section = $0 ?? .all })) {
            Section("Traffic") {
                ForEach(TrafficSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .badge(model.count(in: section))
                        .tag(section)
                }
            }
            if !model.configuration.forwarders.isEmpty {
                Section("MQTT Brokers") {
                    ForEach(model.configuration.forwarders) { forwarder in
                        VStack(alignment: .leading) {
                            Text(forwarder.label)
                            Text("Connect your app to localhost:\(String(forwarder.listenPort))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !model.pinnedHosts.isEmpty {
                Section("Rejected Certificates") {
                    ForEach(model.pinnedHosts, id: \.self) { host in
                        HStack {
                            Label(host, systemImage: "lock.trianglebadge.exclamationmark")
                            Spacer()
                            Button("Bypass") { model.bypass(host: host) }
                                .buttonStyle(.borderless)
                                .help("Stop decrypting \(host); its traffic is relayed untouched")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct TrafficTimeline: View {
    @Bindable var model: CaptureViewModel

    var body: some View {
        let rows = model.visibleRows
        if rows.isEmpty {
            ContentUnavailableView {
                Label(model.searchText.isEmpty ? "No traffic yet" : "No matches", systemImage: "waveform.path.ecg")
            } description: {
                Text(model.isCapturing
                     ? "Point your app or device at the proxy, or at an MQTT forwarder."
                     : "Press Start to begin capturing.")
            }
        } else {
            Table(rows, selection: $model.selection) {
                TableColumn("Time") { row in
                    Text(row.time, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                        .monospacedDigit()
                }
                .width(min: 80, ideal: 95, max: 110)
                TableColumn("") { row in
                    KindBadge(row: row)
                }
                .width(min: 70, ideal: 80, max: 100)
                TableColumn("Host", value: \.host)
                    .width(min: 80, ideal: 150)
                TableColumn("Summary") { row in
                    Text(row.summary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(row.isIssue ? Color.red : Color.primary)
                }
                TableColumn("Size") { row in
                    Text(row.size > 0 ? Formatting.byteCount(row.size) : "")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 70, max: 90)
            }
            .contextMenu(forSelectionType: TrafficRow.ID.self) { ids in
                if let id = ids.first, let row = model.rows.first(where: { $0.id == id }) {
                    TimelineRowMenu(model: model, row: row)
                }
            }
        }
    }
}

/// Right-click actions for a timeline row: the Pro tools that apply to it.
struct TimelineRowMenu: View {
    let model: CaptureViewModel
    let row: TrafficRow

    var body: some View {
        switch row.event {
        case .httpExchange(let exchange):
            Button("Add Breakpoint for \(exchange.method) \(BreakpointLabel.path(exchange.url))") {
                _ = model.addBreakpoint(for: row)
            }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(exchange.url, forType: .string)
            }
        case .mqtt(let capture):
            if case .publish = capture.event.packet {
                Button("Replay…") {
                    if model.prepareReplay(of: row) { model.composer.isPresented = true }
                }
            }
            if let topic = capture.event.resolvedTopic {
                Button("Publish to \(topic)…") {
                    model.preparePublish(toTopic: topic)
                    model.composer.isPresented = true
                }
            }
        default:
            EmptyView()
        }
    }
}

enum BreakpointLabel {
    /// The path of a URL, shortened for a menu item.
    static func path(_ url: String) -> String {
        let withoutScheme = url.components(separatedBy: "://").last ?? url
        let path = withoutScheme.firstIndex(of: "/").map { String(withoutScheme[$0...]) } ?? "/"
        let trimmed = path.split(separator: "?").first.map(String.init) ?? path
        return trimmed.count > 40 ? "…" + trimmed.suffix(39) : trimmed
    }
}

struct KindBadge: View {
    let row: TrafficRow

    var body: some View {
        Text(row.badge)
            .font(.caption2.weight(.semibold).monospaced())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }

    private var color: Color {
        if row.isIssue { return .red }
        switch row.kind {
        case .http: return .blue
        case .mqtt: return .purple
        case .webSocket: return .teal
        case .tunnel: return .gray
        case .tls: return .orange
        }
    }
}

/// The MQTT topics seen so far as an outline, expanded by default.
struct TopicTreeView: View {
    let tree: TopicTree
    @Binding var selection: TopicNode.ID?
    @State private var collapsed: Set<TopicNode.ID> = []

    var body: some View {
        if tree.roots.isEmpty {
            ContentUnavailableView("No topics yet", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text("Topics appear here as PUBLISH packets are captured."))
        } else {
            List(selection: $selection) {
                ForEach(tree.roots) { TopicBranch(node: $0, collapsed: $collapsed) }
            }
        }
    }
}

struct TopicBranch: View {
    let node: TopicNode
    @Binding var collapsed: Set<TopicNode.ID>

    var body: some View {
        if node.children.isEmpty {
            TopicLabel(node: node).tag(node.id)
        } else {
            DisclosureGroup(isExpanded: Binding(
                get: { !collapsed.contains(node.id) },
                set: { expanded in
                    if expanded { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
                }
            )) {
                ForEach(node.children) { TopicBranch(node: $0, collapsed: $collapsed) }
            } label: {
                TopicLabel(node: node)
            }
            .tag(node.id)
        }
    }
}

struct TopicLabel: View {
    let node: TopicNode

    var body: some View {
        HStack {
            Text(node.name)
            if node.retained {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary).help("Retained")
            }
            Spacer()
            if let payload = node.lastPayload, let text = String(bytes: payload.prefix(40), encoding: .utf8) {
                Text(text).lineLimit(1).foregroundStyle(.secondary).font(.callout.monospaced())
            }
            Text("\(node.totalCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .trailing)
        }
    }
}

/// Inspector for the selected topic: counts, retained flag and the latest payload.
struct TopicDetailView: View {
    let tree: TopicTree
    let topic: TopicNode.ID?
    var onPublish: ((String) -> Void)?

    var body: some View {
        if let topic, let node = tree.node(for: topic) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(node.id).font(.headline.monospaced()).textSelection(.enabled)
                        Spacer()
                        if let onPublish {
                            Button {
                                onPublish(node.id)
                            } label: {
                                Label("Publish…", systemImage: "paperplane")
                            }
                            .help("Send a message to this topic (Pro)")
                        }
                    }
                    HStack(spacing: 12) {
                        Text("\(node.messageCount) messages here, \(node.totalCount) including subtopics")
                        if node.retained { Label("Retained", systemImage: "pin.fill") }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    if let updated = node.lastUpdated {
                        Text("Last message \(updated.formatted(date: .omitted, time: .standard))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                Divider()
                if let payload = node.lastPayload {
                    BodyView(bytes: payload, contentType: nil)
                } else {
                    Text("Nothing has been published to this exact topic yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            ContentUnavailableView("No topic selected", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text("Select a topic to see its latest payload."))
        }
    }
}
#endif
