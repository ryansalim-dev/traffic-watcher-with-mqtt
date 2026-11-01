#if os(macOS)
import AppCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: CaptureViewModel
    let certificates: CertificateStorage
    @State var mqttMode = MQTTMode.packets
    /// Topic selected when the topic tree first appears (used for screenshots).
    var initialTopic: String?

    enum MQTTMode: String, CaseIterable, Identifiable {
        case packets = "Packets", topics = "Topics"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } content: {
            Group {
                if model.section == .mqtt && mqttMode == .topics {
                    TopicTreeView(tree: model.topicTree, selected: initialTopic)
                } else {
                    TrafficTimeline(model: model)
                }
            }
            .navigationSplitViewColumnWidth(min: 420, ideal: 620)
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
        } detail: {
            InspectorView(model: model)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                CaptureToggle(model: model)
            }
        }
        .safeAreaInset(edge: .bottom) {
            StatusBar(model: model)
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
            Text("\(model.rows.count) events")
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
        }
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

struct TopicTreeView: View {
    let tree: TopicTree
    @State var selected: TopicNode.ID?

    var body: some View {
        if tree.roots.isEmpty {
            ContentUnavailableView("No topics yet", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text("Topics appear here as PUBLISH packets are captured."))
        } else {
            HSplitView {
                List(tree.roots, children: \.outlineChildren, selection: $selected) { node in
                    HStack {
                        Text(node.name)
                        if node.retained { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        Text("\(node.totalCount)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 220)

                Group {
                    if let id = selected, let node = tree.node(for: id) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(node.id).font(.headline).textSelection(.enabled)
                            if let updated = node.lastUpdated {
                                Text("\(node.messageCount) messages · last \(updated.formatted(date: .omitted, time: .standard))")
                                    .foregroundStyle(.secondary)
                            }
                            BodyView(bytes: node.lastPayload ?? [], contentType: nil)
                        }
                        .padding()
                    } else {
                        Text("Select a topic to see its latest payload").foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
#endif
