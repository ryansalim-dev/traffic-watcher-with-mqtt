#if os(macOS)
import AppCore
import AppKit
import Charts
import SwiftUI

/// The MQTT topics seen so far, as a table: path, last payload, recent rate and message count.
struct TopicTreeView: View {
    let tree: TopicTree
    @Binding var selection: TopicNode.ID?
    @State private var collapsed: Set<TopicNode.ID> = []

    var body: some View {
        if tree.roots.isEmpty {
            ContentUnavailableView("No topics yet", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text("Topics appear here as PUBLISH packets are captured."))
        } else {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                List(selection: $selection) {
                    ForEach(tree.roots) { TopicBranch(node: $0, collapsed: $collapsed, now: context.date) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .safeAreaInset(edge: .top, spacing: 0) { TopicColumnsHeader() }
            }
        }
    }
}

enum TopicColumns {
    static let payload: CGFloat = 220
    static let rate: CGFloat = 96
    static let count: CGFloat = 52
}

struct TopicColumnsHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Topic").frame(maxWidth: .infinity, alignment: .leading)
            Text("Last payload").frame(width: TopicColumns.payload, alignment: .leading)
            Text("Last minute").frame(width: TopicColumns.rate, alignment: .leading)
            Text("Msgs").frame(width: TopicColumns.count, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.leading, 30)
        .padding(.trailing, 22)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

struct TopicBranch: View {
    let node: TopicNode
    @Binding var collapsed: Set<TopicNode.ID>
    let now: Date

    var body: some View {
        if node.children.isEmpty {
            TopicRow(node: node, now: now).tag(node.id)
        } else {
            DisclosureGroup(isExpanded: Binding(
                get: { !collapsed.contains(node.id) },
                set: { expanded in
                    if expanded { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
                }
            )) {
                ForEach(node.children) { TopicBranch(node: $0, collapsed: $collapsed, now: now) }
            } label: {
                TopicRow(node: node, now: now)
            }
            .tag(node.id)
        }
    }
}

struct TopicRow: View {
    let node: TopicNode
    let now: Date

    var body: some View {
        let isGroup = !node.children.isEmpty
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(node.name)
                    .fontWeight(isGroup ? .semibold : .medium)
                    .lineLimit(1)
                if node.retained {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.tertiary).help("Retained")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let payload = node.lastPayload {
                    Text(Self.preview(payload))
                        .font(Theme.monoSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Color.clear
                }
            }
            .frame(width: TopicColumns.payload, alignment: .leading)

            Group {
                if node.messageCount > 0 {
                    Sparkline(values: ActivityHistogram.counts(of: node.history.map(\.date), buckets: 12, bucketLength: 5, endingAt: now),
                              color: Theme.mqtt, filled: false)
                } else {
                    Color.clear
                }
            }
            .frame(width: TopicColumns.rate, height: 16)

            Text(node.totalCount.formatted())
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: TopicColumns.count, alignment: .trailing)
        }
        .frame(minHeight: 22)
    }

    static func preview(_ payload: [UInt8]) -> String {
        guard let text = String(bytes: payload.prefix(120), encoding: .utf8) else {
            return Formatting.byteCount(payload.count) + " binary"
        }
        return text.replacingOccurrences(of: "\n", with: " ")
    }
}

/// Inspector for the selected topic: actions, counts, a chart of numeric fields and the latest payload.
struct TopicDetailView: View {
    let tree: TopicTree
    let topic: TopicNode.ID?
    var onPublish: ((String) -> Void)?
    @State private var field: String?

    var body: some View {
        if let topic, let node = tree.node(for: topic) {
            let series = NumericSeries.series(from: node.history)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TypePill(text: node.children.isEmpty ? "TOPIC" : "BRANCH", color: Theme.mqtt, fixedWidth: nil)
                        if let updated = node.lastUpdated {
                            Text("Last message \(updated.formatted(date: .omitted, time: .standard))")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    TopicPathText(path: node.id)
                    HStack(spacing: 8) {
                        if let onPublish {
                            Button {
                                onPublish(node.id)
                            } label: {
                                Label("Publish…", systemImage: "paperplane")
                            }
                            .buttonStyle(.borderedProminent)
                            .help("Send a message to this topic (Pro)")
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(node.id, forType: .string)
                        } label: {
                            Label("Copy Topic", systemImage: "doc.on.doc")
                        }
                    }
                    .controlSize(.small)
                }
                .padding(16)

                TopicStats(node: node)

                if !series.isEmpty {
                    let selected = series.first { $0.field == field } ?? series[0]
                    FieldChart(series: series, selected: selected) { field = $0 }
                }

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
                                   description: Text("Select a topic to see its latest payload and history."))
        }
    }
}

/// A topic path in monospace with the parent levels dimmed and the last level bold.
struct TopicPathText: View {
    let path: String

    var body: some View {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let parent = parts.dropLast().map { $0 + "/" }.joined()
        (Text(parent).foregroundStyle(.tertiary) + Text(String(parts.last ?? "")).foregroundStyle(.primary).fontWeight(.semibold))
            .font(.system(size: 13.5, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(3)
    }
}

struct TopicStats: View {
    let node: TopicNode

    var body: some View {
        let perMinute = node.history.filter { $0.date > Date().addingTimeInterval(-60) }.count
        HStack(spacing: 1) {
            stat("Messages", node.messageCount.formatted())
            stat("Last min", perMinute.formatted())
            stat("Incl. subtopics", node.totalCount.formatted())
            stat("Retained", node.retained ? "Yes" : "No")
        }
        .background(Theme.hairline)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            CapsLabel(label)
            Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A line chart of one numeric payload field over the topic's recent messages.
struct FieldChart: View {
    let series: [NumericSeries]
    let selected: NumericSeries
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if series.count > 1 {
                    Picker("Field", selection: Binding(get: { selected.field }, set: onSelect)) {
                        ForEach(series) { Text($0.field).tag($0.field) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                } else {
                    Text(selected.field).font(.system(size: 12, weight: .medium, design: .monospaced))
                }
                Text("last \(selected.points.count) messages").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                Spacer()
                if let latest = selected.latest, let low = selected.minimum, let high = selected.maximum {
                    Text(Self.format(latest)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    Text("min \(Self.format(low)) · max \(Self.format(high))")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            Chart(Array(selected.points.enumerated()), id: \.offset) { _, point in
                AreaMark(x: .value("Time", point.date), y: .value(selected.field, point.value))
                    .foregroundStyle(LinearGradient(colors: [Theme.mqtt.opacity(0.22), Theme.mqtt.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.date), y: .value(selected.field, point.value))
                    .foregroundStyle(Theme.mqtt)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute().second())
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel()
                }
            }
            .frame(height: 110)
        }
        .padding(16)
    }

    static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
#endif
