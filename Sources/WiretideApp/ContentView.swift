#if os(macOS)
import AppCore
import AppKit
import Licensing
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
    @AppStorage(RowDensity.storageKey) private var density = RowDensity.regular

    enum MQTTMode: String, CaseIterable, Identifiable {
        case packets = "Packets", topics = "Topics"
        var id: String { rawValue }
    }

    private var showsTopics: Bool { model.section == .mqtt && mqttMode == .topics }
    private var showsSetup: Bool { model.rows.isEmpty && model.searchText.isEmpty }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, license: license)
                .navigationSplitViewColumnWidth(min: 200, ideal: 228)
        } detail: {
            Group {
                if showsTopics {
                    TopicTreeView(tree: model.topicTree, filter: model.searchText, selection: $selectedTopic)
                } else if showsSetup {
                    SetupView(model: model)
                } else {
                    TrafficTimeline(model: model, density: density)
                        .safeAreaInset(edge: .top, spacing: 0) { FilterBar(model: model) }
                }
            }
            .frame(minWidth: 460)
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
            .inspector(isPresented: showsSetup ? .constant(false) : $showInspector) {
                Group {
                    if showsTopics {
                        TopicDetailView(model: model, topic: selectedTopic) { topic in
                            model.preparePublish(toTopic: topic)
                            model.composer.isPresented = true
                        } onReplayLast: { topic in
                            if model.prepareReplayOfLatest(onTopic: topic) { model.composer.isPresented = true }
                        }
                    } else {
                        InspectorView(model: model)
                    }
                }
                .inspectorColumnWidth(min: 320, ideal: 420, max: 800)
                .toolbar {
                    ToolbarItem {
                        InspectorCopyButton(model: model, topic: showsTopics ? selectedTopic : nil)
                    }
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
        .tint(Theme.accent)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                RecordingCapsule(model: model)
            }
            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(text: $model.searchText,
                                   prompt: showsTopics ? "Filter topics" : "Filter URLs, headers, topics, payloads")
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
            MQTTComposerView(composer: model.composer,
                             suggestions: model.topicSuggestions(excluding: model.composer.topic)) { model.composer.isPresented = false }
        }
        .sheet(item: Binding(get: { model.breakpoints.paused.first }, set: { _ in })) { item in
            BreakpointEditor(center: model.breakpoints, item: item)
                .id(item.id)
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

// MARK: Toolbar

/// Start and stop capture. While recording it shows the elapsed time, recent activity and the event count.
struct RecordingCapsule: View {
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
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill((model.isCapturing ? Theme.failure : Theme.accent).opacity(0.18))
                        .frame(width: 22, height: 22)
                    if model.isCapturing {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Theme.failure).frame(width: 8, height: 8)
                    } else {
                        Circle().fill(Theme.accent).frame(width: 9, height: 9)
                    }
                }
                if let started = model.captureStartedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        HStack(spacing: 9) {
                            HStack(spacing: 6) {
                                StatusDot(color: Theme.failure, halo: true)
                                Text("Recording").fontWeight(.semibold)
                            }
                            Text(Self.elapsed(from: started, to: context.date))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Sparkline(values: model.activity(now: context.date))
                                .frame(width: 56, height: 16)
                            Text(countLabel)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Start Recording").fontWeight(.semibold)
                }
            }
            .font(.system(size: 12.5))
            .lineLimit(1)
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .frame(height: 28)
            .background(Theme.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(model.isCapturing ? "Stop recording (⌘R)" : "Start the proxy and MQTT forwarders (⌘R)")
        .accessibilityLabel(model.isCapturing ? "Stop recording" : "Start recording")
    }

    private var countLabel: String {
        if model.section == .mqtt {
            return "\(model.count(in: .mqtt).formatted()) packets"
        }
        return "\(model.rows.count.formatted()) events"
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// One-click filters above the timeline, plus the host picked in the sidebar.
struct FilterBar: View {
    @Bindable var model: CaptureViewModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(QuickFilter.allCases) { filter in
                FilterChip(title: filter.title, swatch: swatch(for: filter), isOn: model.quickFilter == filter) {
                    model.quickFilter = filter
                }
            }
            if let host = model.hostFilter {
                Divider().frame(height: 14).padding(.horizontal, 4)
                Button {
                    model.hostFilter = nil
                } label: {
                    HStack(spacing: 5) {
                        HostMonogram(host: host, size: 14)
                        Text(host)
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Show every host again")
            }
            if let method = model.methodFilter {
                ActiveFilterChip(title: "Method \(method)") { model.methodFilter = nil }
            }
            if let statusClass = model.statusClassFilter {
                ActiveFilterChip(title: "Status \(statusClass)xx") { model.statusClassFilter = nil }
            }
            AddFilterMenu(model: model)
            Spacer(minLength: 8)
            Text(model.visibleRows.count == model.rows.count
                 ? "\(model.rows.count.formatted()) events"
                 : "\(model.visibleRows.count.formatted()) of \(model.rows.count.formatted())")
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func swatch(for filter: QuickFilter) -> Color? {
        switch filter {
        case .all: nil
        case .json: Theme.get
        case .media: Theme.put
        case .errors: Theme.failure
        case .publish: Theme.mqtt
        }
    }
}

/// A filter added from "+ Filter", with an x to remove it.
struct ActiveFilterChip: View {
    let title: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Text(title)
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Theme.accent.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Remove this filter")
    }
}

/// "+ Filter": narrow the list by method, status class or host.
struct AddFilterMenu: View {
    @Bindable var model: CaptureViewModel
    private static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var body: some View {
        Menu {
            Menu("Method") {
                ForEach(Self.methods, id: \.self) { method in
                    Button(method) { model.methodFilter = method }
                }
            }
            Menu("Status") {
                ForEach(2...5, id: \.self) { statusClass in
                    Button("\(statusClass)xx") { model.statusClassFilter = statusClass }
                }
            }
            let hosts = model.topHosts(limit: 12)
            if !hosts.isEmpty {
                Menu("Host") {
                    ForEach(hosts) { entry in
                        Button(entry.host) { model.hostFilter = entry.host }
                    }
                }
            }
        } label: {
            Text("+ Filter")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 6)
        .help("Filter by method, status or host")
    }
}

/// Always-visible filter field for the toolbar, like the mockup's, focused with ⌘F.
struct ToolbarSearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("Filter", text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onSubmit { focused = true }
                .onExitCommand { text = ""; focused = false }
            if text.isEmpty {
                Text("⌘F")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .frame(height: 17)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline))
            } else {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 280, height: 28)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.8) : .clear, lineWidth: 1)
        }
        .background {
            Button("Find") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }
}

/// Copies the selected request as cURL, or the selected topic, from the inspector's toolbar.
struct InspectorCopyButton: View {
    let model: CaptureViewModel
    let topic: String?

    var body: some View {
        Button {
            if let text = textToCopy { copyToPasteboard(text) }
        } label: {
            Label(help, systemImage: "doc.on.doc")
        }
        .disabled(textToCopy == nil)
        .help(help)
    }

    private var help: String {
        if topic != nil { return "Copy Topic" }
        if case .httpExchange? = model.selectedRow?.event { return "Copy as cURL" }
        return "Copy Summary"
    }

    private var textToCopy: String? {
        if let topic { return topic }
        guard let row = model.selectedRow else { return nil }
        switch row.event {
        case .httpExchange(let exchange): return exchange.curlCommand
        case .webSocketMessage(let message): return String(bytes: message.payload, encoding: .utf8) ?? row.summary
        default: return row.summary
        }
    }
}

struct FilterChip: View {
    let title: String
    let swatch: Color?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let swatch { Circle().fill(swatch).frame(width: 6, height: 6) }
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .foregroundStyle(isOn ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.secondary))
            .background(isOn ? AnyShapeStyle(Color.primary.opacity(0.85)) : AnyShapeStyle(Color.clear), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: Sidebar

struct SidebarView: View {
    @Bindable var model: CaptureViewModel
    let license: LicenseManager

    var body: some View {
        List(selection: Binding(get: { model.section }, set: { model.section = $0 ?? .all })) {
            Section("Capture") {
                ForEach(TrafficSection.allCases) { section in
                    HStack(spacing: 0) {
                        Label {
                            Text(section.title)
                        } icon: {
                            Image(systemName: section.symbol).foregroundStyle(color(for: section))
                        }
                        Spacer(minLength: 6)
                        count(for: section)
                    }
                    .tag(section)
                }
            }
            let hosts = model.topHosts()
            if !hosts.isEmpty {
                Section("Hosts") {
                    ForEach(hosts) { entry in
                        HostRow(entry: entry, isOn: model.hostFilter == entry.host) {
                            model.hostFilter = model.hostFilter == entry.host ? nil : entry.host
                        }
                    }
                }
            }
            if !model.configuration.forwarders.isEmpty {
                Section("Brokers") {
                    ForEach(model.configuration.forwarders) { forwarder in
                        HStack(spacing: 9) {
                            StatusDot(color: model.isCapturing ? Theme.success : Theme.neutral, halo: model.isCapturing)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(forwarder.brokerHost).lineLimit(1)
                                    if forwarder.useTLS {
                                        Text("TLS").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                                    }
                                }
                                Text(":\(String(forwarder.listenPort)) → :\(String(forwarder.brokerPort)) · \(brokerStatus(forwarder))")
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                        .help("Connect your app to localhost:\(String(forwarder.listenPort)) to capture \(forwarder.label)")
                    }
                }
            }
            if !model.pinnedHosts.isEmpty {
                Section("Rejected Certificates") {
                    ForEach(model.pinnedHosts, id: \.self) { host in
                        HStack {
                            Label {
                                Text(host).lineLimit(1).truncationMode(.middle)
                            } icon: {
                                Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(Theme.failure)
                            }
                            Spacer()
                            Button("Bypass") { model.bypass(host: host) }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .help("Stop decrypting \(host); its traffic is relayed untouched")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter(model: model, license: license)
        }
    }

    private func brokerStatus(_ forwarder: ForwarderConfiguration) -> String {
        guard model.isCapturing else { return "idle" }
        let rate = model.messagesPerSecond(broker: "\(forwarder.brokerHost):\(forwarder.brokerPort)")
        return rate < 0.1 && rate > 0 ? "<1 msg/s" : "\(Int(rate.rounded())) msg/s"
    }

    private func color(for section: TrafficSection) -> Color {
        switch section {
        case .all, .http: Theme.accent
        case .mqtt: Theme.mqtt
        case .webSocket: Theme.webSocket
        case .issues: Theme.failure
        }
    }

    /// Plain counts, as in the mockup; Issues turns red when there are any.
    private func count(for section: TrafficSection) -> some View {
        let count = model.count(in: section)
        let isAlert = section == .issues && count > 0
        return Text(count.formatted())
            .font(.system(size: 11.5, weight: isAlert ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(isAlert ? AnyShapeStyle(Theme.failure) : AnyShapeStyle(.tertiary))
    }
}

struct HostRow: View {
    let entry: HostCount
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                HostMonogram(host: entry.host)
                Text(entry.host)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                    .fontWeight(isOn ? .semibold : .regular)
                Spacer(minLength: 4)
                Text(entry.count.formatted())
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Show every host" : "Show only \(entry.host)")
    }
}

/// A rounded tile with the host's first letter, colored consistently per host.
struct HostMonogram: View {
    let host: String
    var size: CGFloat = 18

    var body: some View {
        Text(String(host.first.map { $0.uppercased() } ?? "?"))
            .font(.system(size: size * 0.56, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.monogramColor(for: host), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Proxy status and address, paused breakpoints and the license, pinned under the sidebar.
struct SidebarFooter: View {
    let model: CaptureViewModel
    let license: LicenseManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.breakpoints.paused.isEmpty {
                Label("\(model.breakpoints.paused.count) paused at breakpoints", systemImage: "pause.circle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.warning)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    StatusDot(color: model.isCapturing ? Theme.success : Theme.neutral, halo: model.isCapturing)
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let address {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(address, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Copy the proxy address")
                    }
                }
                Text(detail)
                    .font(Theme.monoSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            SettingsLink {
                HStack(spacing: 8) {
                    LicenseChip(isPro: license.entitlement.isPro)
                    Text(licenseLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(license.summary)
        }
        .padding(12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var licenseLine: String {
        if case .pro(let coveredUntil) = license.entitlement {
            return "Updates until \(coveredUntil.formatted(.dateTime.month(.abbreviated).year()))"
        }
        return "Free plan · Upgrade"
    }

    private var title: String {
        guard model.isCapturing else { return "Proxy idle" }
        return model.systemProxyActive ? "System proxy on" : "Proxy running"
    }

    private var address: String? {
        model.proxyPort.map { "\(model.configuration.allowRemoteDevices ? "0.0.0.0" : "127.0.0.1"):\(String($0))" }
    }

    private var detail: String {
        let port = String(model.proxyPort ?? model.configuration.proxyPort)
        let host = model.configuration.allowRemoteDevices ? "All interfaces" : "127.0.0.1"
        let https = model.configuration.decryptHTTPS ? "HTTPS decrypted" : "HTTPS relayed"
        return "\(host):\(port) · \(https)"
    }
}

struct LicenseChip: View {
    let isPro: Bool

    var body: some View {
        Text(isPro ? "PRO" : "FREE")
            .font(.system(size: 10, weight: .bold))
            .kerning(0.5)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .foregroundStyle(isPro ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .background(
                isPro
                    ? AnyShapeStyle(LinearGradient(colors: [Theme.accent.opacity(0.32), Theme.mqtt.opacity(0.28)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyShapeStyle(Theme.fill),
                in: Capsule())
    }
}

// MARK: Timeline

struct TrafficTimeline: View {
    @Bindable var model: CaptureViewModel
    let density: RowDensity
    /// Code and Duration only mean something for HTTP, so they are hidden in the MQTT section.
    @State private var columns = TableColumnCustomization<TrafficRow>()

    var body: some View {
        let rows = model.visibleRows
        if rows.isEmpty {
            ContentUnavailableView {
                Label("No matches", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Nothing captured so far matches the search and filters.")
            } actions: {
                Button("Clear Filters") {
                    model.searchText = ""
                    model.quickFilter = .all
                    model.hostFilter = nil
                }
            }
        } else {
            let longest = rows.lazy.compactMap(\.duration).max() ?? 1
            Table(rows, selection: $model.selection, columnCustomization: $columns) {
                TableColumn("") { row in
                    StatusDot(color: Theme.color(for: row.tone))
                        .frame(maxWidth: .infinity)
                        .frame(height: density.contentHeight)
                }
                .width(12)
                .customizationID("status")
                TableColumn("Type") { row in
                    TypePill(text: row.pill, color: Theme.color(forPill: row.pill, kind: row.kind))
                }
                .width(64)
                .customizationID("type")
                TableColumn("Host / Path") { row in
                    HostPathCell(row: row)
                }
                .width(min: 200, ideal: 360)
                .customizationID("hostPath")
                TableColumn("Code") { row in
                    Text(row.statusCode.map(String.init) ?? "")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.color(forStatus: row.statusCode))
                }
                .width(40)
                .customizationID("code")
                TableColumn("Duration") { row in
                    if let duration = row.duration {
                        DurationCell(duration: duration, longest: longest)
                    }
                }
                .width(120)
                .customizationID("duration")
                TableColumn("Size") { row in
                    Text(row.size > 0 ? Formatting.compactByteCount(row.size) : "—")
                        .monospacedDigit()
                        .foregroundStyle(row.size > 0 ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.quaternary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(72)
                .customizationID("size")
                TableColumn("Time") { row in
                    Text(row.time, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
                        .secondFraction(.fractional(3)))
                        .font(Theme.monoSmall)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(100)
                .customizationID("time")
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .onChange(of: model.section, initial: true) {
                let visibility: Visibility = model.section == .mqtt ? .hidden : .automatic
                columns[visibility: "code"] = visibility
                columns[visibility: "duration"] = visibility
            }
            .contextMenu(forSelectionType: TrafficRow.ID.self) { ids in
                if let id = ids.first, let row = model.rows.first(where: { $0.id == id }) {
                    TimelineRowMenu(model: model, row: row)
                }
            }
        }
    }
}

/// The host, dimmed, followed by the path or summary, which truncates first.
struct HostPathCell: View {
    let row: TrafficRow

    var body: some View {
        HStack(spacing: 0) {
            Text(row.host)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            if row.kind != .http && row.kind != .webSocket && !row.host.isEmpty {
                Text("  ›  ").foregroundStyle(.tertiary)
            }
            Text(row.detail)
                .foregroundStyle(row.isIssue ? AnyShapeStyle(Theme.failure) : AnyShapeStyle(.primary))
                .truncationMode(.tail)
        }
        .font(Theme.mono)
        .lineLimit(1)
        .help(row.summary)
    }
}

/// A bar scaled to the slowest visible request, then the time. Slow requests turn amber.
struct DurationCell: View {
    let duration: TimeInterval
    let longest: TimeInterval

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fill)
                    Capsule()
                        .fill(duration > 1 ? Theme.warning : Theme.accent)
                        .opacity(0.85)
                        .frame(width: max(3, proxy.size.width * min(1, duration / max(longest, 0.001))))
                }
            }
            .frame(height: 6)
            Text(Formatting.duration(duration))
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

// MARK: Setup

/// Shown before anything is captured: one primary action and the three ways to get traffic in.
struct SetupView: View {
    let model: CaptureViewModel

    var body: some View {
        let configuration = model.configuration
        ScrollView {
            VStack(spacing: 14) {
                WaveMark()
                    .frame(width: 88, height: 56)
                Text(model.isCapturing ? "Waiting for traffic" : "Ready to capture")
                    .font(.system(size: 22, weight: .semibold))
                    .kerning(-0.3)
                Text(model.isCapturing
                     ? "Wiretide is listening on port \(String(model.proxyPort ?? configuration.proxyPort)). Requests and MQTT packets appear here as soon as something connects."
                     : configuration.setSystemProxy
                        ? "Wiretide sets itself as this Mac's proxy while recording and puts everything back when you stop."
                        : "Point your app or device at the proxy, or at an MQTT forwarder, then start recording.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                if !model.isCapturing {
                    Button {
                        Task { await model.startCapture() }
                    } label: {
                        HStack(spacing: 8) {
                            Circle().frame(width: 9, height: 9)
                            Text("Start Recording")
                            Text("⌘R").opacity(0.7)
                        }
                        .font(.system(size: 13.5, weight: .semibold))
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .foregroundStyle(Theme.onAccent)
                        .background(Theme.accent, in: Capsule())
                        .shadow(color: Theme.accent.opacity(0.45), radius: 10, y: 6)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                HStack(alignment: .top, spacing: 12) {
                    SetupCard(symbol: "laptopcomputer", tint: Theme.accent, title: "This Mac",
                              message: "Apps and the Simulator on this Mac go through Wiretide.",
                              status: configuration.setSystemProxy ? "System proxy switches on with recording" : nil,
                              link: configuration.setSystemProxy ? nil : "Turn on in Settings › Proxy")
                    SetupCard(symbol: "iphone", tint: Theme.accent, title: "iPhone or another device",
                              message: "Install the Wiretide certificate, then set the Wi‑Fi proxy to this Mac on port \(String(configuration.proxyPort)).",
                              status: configuration.allowRemoteDevices ? "Accepting other devices" : nil,
                              link: configuration.allowRemoteDevices ? nil : "Allow other devices in Settings › Proxy")
                    SetupCard(symbol: "antenna.radiowaves.left.and.right", tint: Theme.mqtt, title: "MQTT broker",
                              message: "Add a broker, then connect your device to the local port instead.",
                              status: configuration.forwarders.isEmpty ? nil
                                : "\(configuration.forwarders.count) broker\(configuration.forwarders.count == 1 ? "" : "s") ready",
                              link: configuration.forwarders.isEmpty ? "Add one in Settings › MQTT" : nil)
                }
                .frame(maxWidth: 680)
                .padding(.top, 14)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
    }
}

struct SetupCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    let status: String?
    let link: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status {
                Label(status, systemImage: "checkmark")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.success)
            } else if let link {
                SettingsLink {
                    Text("\(link) →").font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// Two offset swells, Wiretide's mark for the empty state.
struct WaveMark: View {
    var body: some View {
        Canvas { context, size in
            func wave(baseline: CGFloat, amplitude: CGFloat) -> Path {
                var path = Path()
                let steps = 80
                for step in 0...steps {
                    let x = size.width * CGFloat(step) / CGFloat(steps)
                    let y = baseline - amplitude * sin(CGFloat(step) / CGFloat(steps) * .pi * 3.2)
                    if step == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                return path
            }
            context.stroke(wave(baseline: size.height * 0.78, amplitude: size.height * 0.2), with: .color(Theme.accent.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
            context.stroke(wave(baseline: size.height * 0.55, amplitude: size.height * 0.3), with: .color(Theme.accent),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .accessibilityHidden(true)
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
#endif
