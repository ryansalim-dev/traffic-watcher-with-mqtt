#if os(macOS)
import AppCore
import AppKit
import Charts
import ProxyCore
import SwiftUI

/// The MQTT topics seen so far, as a table: path, last payload, recent rate and message count.
struct TopicTreeView: View {
    let tree: TopicTree
    var filter = ""
    @Binding var selection: TopicNode.ID?
    @State private var collapsed: Set<TopicNode.ID> = []

    var body: some View {
        let roots = tree.filtered(matching: filter)
        if tree.roots.isEmpty {
            ContentUnavailableView("No topics yet", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text("Topics appear here as PUBLISH packets are captured."))
        } else if roots.isEmpty {
            ContentUnavailableView.search(text: filter)
        } else {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                List(selection: $selection) {
                    ForEach(roots) { TopicBranch(node: $0, collapsed: $collapsed, now: context.date) }
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
            Text("Rate").frame(width: TopicColumns.rate, alignment: .leading)
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
    let model: CaptureViewModel
    let topic: TopicNode.ID?
    var onPublish: (String) -> Void
    var onReplayLast: (String) -> Void
    @State private var field: String?
    @State private var tab: Tab = .latest

    enum Tab: Hashable { case latest, history, properties }

    var body: some View {
        if let topic, let node = model.topicTree.node(for: topic) {
            let publishes = model.publishes(onTopic: node.id)
            let latest = publishes.last
            let series = NumericSeries.series(from: node.history)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TypePill(text: node.children.isEmpty ? "TOPIC" : "BRANCH", color: Theme.mqtt, fixedWidth: nil)
                        if let latest {
                            Text(latest.broker).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    TopicPathText(path: node.id)
                    HStack(spacing: 8) {
                        Button {
                            onPublish(node.id)
                        } label: {
                            Label("Publish…", systemImage: "paperplane")
                        }
                        .buttonStyle(ChipButtonStyle(prominent: true))
                        .help("Send a message to this topic (Pro)")
                        Button("Replay last") { onReplayLast(node.id) }
                            .buttonStyle(ChipButtonStyle())
                            .disabled(latest == nil)
                            .help("Send the latest message on this topic again (Pro)")
                        Button {
                            copyToPasteboard(node.id)
                        } label: {
                            Label("Copy topic", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(ChipButtonStyle())
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 14)

                TimelineView(.periodic(from: .now, by: 5)) { context in
                    TopicStats(node: node, latest: latest, now: context.date)
                }

                if !series.isEmpty {
                    let selected = series.first { $0.field == field } ?? series[0]
                    FieldChart(series: series, selected: selected) { field = $0 }
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                }

                InspectorTabs(tabs: [(Tab.latest, "Latest payload", nil), (.history, "History", publishes.count),
                                     (.properties, "Properties", nil)],
                              selection: $tab,
                              trailing: node.lastUpdated.map { $0.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))) })

                switch tab {
                case .latest:
                    if let payload = node.lastPayload {
                        BodyPanel(bytes: payload, contentType: nil, emptyText: "Empty payload")
                    } else {
                        Text("Nothing has been published to this exact topic yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .history:
                    TopicHistoryList(samples: node.history)
                case .properties:
                    if let latest {
                        KeyValueList(rows: MQTTDescriber.rows(for: latest.event).map { ($0.label, $0.value) },
                                     nameWidth: 120, monospacedValues: false)
                    } else {
                        Text("No message captured on this topic.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        } else {
            ContentUnavailableView("No topic selected", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text("Select a topic to see its latest payload and history."))
        }
    }
}

/// Recent messages on a topic, newest first.
struct TopicHistoryList: View {
    let samples: [TopicSample]

    var body: some View {
        List {
            ForEach(Array(samples.enumerated().reversed()), id: \.offset) { _, sample in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(sample.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: 92, alignment: .leading)
                    Text(TopicRow.preview(sample.payload))
                        .font(Theme.monoSmall)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
    let latest: MQTTCaptureEvent?
    let now: Date

    var body: some View {
        let lastMinute = node.history.filter { $0.date > now.addingTimeInterval(-60) }.count
        HStack(spacing: 1) {
            stat("Messages", node.messageCount.formatted())
            stat("Rate", RateFormat.perSecond(Double(lastMinute) / 60))
            stat("QoS", qos)
            stat("Retained", node.retained ? "Yes" : "No")
        }
        .background(Theme.hairline)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var qos: String {
        guard let latest, case .publish(let publish) = latest.event.packet else { return "–" }
        return String(publish.qos.rawValue)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            CapsLabel(label).lineLimit(1).minimumScaleFactor(0.75)
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if series.count > 1 {
                    Menu {
                        ForEach(series) { item in
                            Button(item.field) { onSelect(item.field) }
                        }
                    } label: {
                        Text(selected.field).font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Chart another numeric field")
                } else {
                    Text(selected.field).font(.system(size: 12, weight: .medium, design: .monospaced))
                }
                if let span = Self.span(selected) {
                    Text("last \(span)").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                Spacer()
                if let latest = selected.latest, let low = selected.minimum, let high = selected.maximum {
                    (Text(Self.format(latest)).fontWeight(.semibold)
                        + Text("  min \(Self.format(low)) · max \(Self.format(high))").foregroundStyle(.tertiary))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .help("Lowest and highest of the last \(selected.points.count) messages")
                }
            }
            .lineLimit(1)
            let (lowY, highY) = Self.domain(selected)
            Chart {
                ForEach(Array(selected.points.enumerated()), id: \.offset) { _, point in
                    AreaMark(x: .value("Time", point.date), yStart: .value("Floor", lowY), yEnd: .value(selected.field, point.value))
                        .foregroundStyle(LinearGradient(colors: [Theme.mqtt.opacity(0.28), Theme.mqtt.opacity(0.03)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.date), y: .value(selected.field, point.value))
                        .foregroundStyle(Theme.mqtt)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if let last = selected.points.last {
                    PointMark(x: .value("Time", last.date), y: .value(selected.field, last.value))
                        .foregroundStyle(Theme.mqtt)
                        .symbolSize(28)
                }
            }
            .chartYScale(domain: lowY...highY)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel().font(.system(size: 10.5))
                }
            }
            .frame(height: 96)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// How much time the chart covers, such as "4 min" or "40 s".
    static func span(_ series: NumericSeries) -> String? {
        guard let first = series.points.first?.date, let last = series.points.last?.date, last > first else { return nil }
        let seconds = Int(last.timeIntervalSince(first).rounded())
        if seconds < 90 { return "\(seconds) s" }
        if seconds < 90 * 60 { return "\(Int((Double(seconds) / 60).rounded())) min" }
        return "\(Int((Double(seconds) / 3600).rounded())) h"
    }

    /// The y range: the data's range with a little headroom, never zero height.
    static func domain(_ series: NumericSeries) -> (Double, Double) {
        let low = series.minimum ?? 0, high = series.maximum ?? 1
        let pad = max((high - low) * 0.15, abs(high) * 0.01, 0.01)
        return (low - pad, high + pad)
    }

    static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
#endif
