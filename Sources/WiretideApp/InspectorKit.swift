#if os(macOS)
import AppCore
import AppKit
import ProxyCore
import SwiftUI

// MARK: Code

extension Theme {
    static func color(for token: CodeToken.Kind) -> Color? {
        switch token {
        case .plain: nil
        case .key: get
        case .string: post
        case .number: put
        case .literal: mqtt
        }
    }
}

/// Read-only code with line numbers, JSON colored when asked. Scrolls both ways and keeps lines unwrapped.
struct CodeText: View {
    let text: String
    var highlightJSON = false
    var fontSize: CGFloat = 12
    /// Above this the text is shown plain, without numbers or colors, to keep large bodies fast.
    static let highlightLimit = 300_000

    var body: some View {
        let (numbers, content) = Self.render(text, json: highlightJSON)
        GeometryReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                HStack(alignment: .top, spacing: 14) {
                    if let numbers {
                        Text(numbers)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.trailing)
                            .accessibilityHidden(true)
                    }
                    Text(content)
                        .textSelection(.enabled)
                }
                .font(.system(size: fontSize, design: .monospaced))
                .lineSpacing(fontSize * 0.45)
                .fixedSize()
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
            }
        }
    }

    static func render(_ text: String, json: Bool) -> (String?, AttributedString) {
        guard text.utf8.count <= highlightLimit else { return (nil, AttributedString(text)) }
        let lines: [[CodeToken]] = json
            ? JSONHighlighter.lines(text)
            : text.split(separator: "\n", omittingEmptySubsequences: false).map { [CodeToken(.plain, String($0))] }
        var content = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { content.append(AttributedString("\n")) }
            for token in line {
                var part = AttributedString(token.text)
                if let color = Theme.color(for: token.kind) { part.foregroundColor = color }
                content.append(part)
            }
        }
        let numbers = (1...max(lines.count, 1)).map(String.init).joined(separator: "\n")
        return (numbers, content)
    }
}

// MARK: Tabs and lists

/// An underlined tab strip, as in the inspector mockup, with optional text on the right.
struct InspectorTabs<Tab: Hashable>: View {
    let tabs: [(tab: Tab, title: String, count: Int?)]
    @Binding var selection: Tab
    var trailing: String?

    var body: some View {
        HStack(spacing: 18) {
            ForEach(tabs, id: \.tab) { item in
                Button {
                    selection = item.tab
                } label: {
                    HStack(spacing: 4) {
                        Text(item.title)
                        if let count = item.count {
                            Text(count.formatted()).foregroundStyle(.tertiary).monospacedDigit()
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(selection == item.tab ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(selection == item.tab ? Theme.accent : .clear)
                            .frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == item.tab ? .isSelected : [])
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 36)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// Monospaced name and value pairs, names dimmed in a fixed column.
struct KeyValueList: View {
    let rows: [(String, String)]
    var nameWidth: CGFloat = 128
    var monospacedValues = true

    var body: some View {
        if rows.isEmpty {
            Text("None").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 7) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.0)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: nameWidth, alignment: .leading)
                                .lineLimit(2)
                            Text(row.1)
                                .font(monospacedValues ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
    }
}

// MARK: Buttons and fields

/// The small rounded buttons from the mockups: a quiet fill, or teal for the main action.
struct ChipButtonStyle: ButtonStyle {
    var prominent = false
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .labelStyle(ChipLabelStyle())
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(prominent ? AnyShapeStyle(Theme.onAccent)
                             : selected ? AnyShapeStyle(Theme.accent)
                             : configuration.role == .destructive ? AnyShapeStyle(Theme.failure) : AnyShapeStyle(.primary))
            .background(background, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.hairline)
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
    }

    private var background: AnyShapeStyle {
        if prominent { return AnyShapeStyle(Theme.accent) }
        if selected { return AnyShapeStyle(Theme.accent.opacity(0.14)) }
        return AnyShapeStyle(Theme.fill)
    }
}

/// Smaller variant for toolbars inside panes ("Tree", "Hex", "Copy").
struct MiniButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 7)
            .frame(height: 20)
            .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            .background(selected ? AnyShapeStyle(Theme.accent.opacity(0.14)) : AnyShapeStyle(Theme.fill),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11.5))
            configuration.title
        }
    }
}

/// A text field drawn as a quiet rounded box, with a teal ring while focused.
struct BoxedTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String?
    var monospaced = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: prompt.map { Text($0) })
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 12.5))
            .focused($focused)
            .boxed(focused: focused)
    }
}

extension View {
    /// The rounded field look shared by text fields and small editors in the sheets.
    func boxed(focused: Bool = false) -> some View {
        padding(.horizontal, 9)
            .frame(minHeight: 28)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(focused ? Theme.accent : Theme.hairline, lineWidth: focused ? 1 : 0.5)
            }
            .shadow(color: focused ? Theme.accent.opacity(0.3) : .clear, radius: 3)
    }
}

/// An uppercase field label with its control below, as in the sheets.
struct FieldGroup<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CapsLabel(label)
            content
        }
    }
}

/// A two-line flow of small views that wraps when it runs out of width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: Timing

extension Theme {
    static func color(for phase: HTTPTiming.Phase) -> Color {
        switch phase {
        case .dns: neutral
        case .connect: put
        case .tls: mqtt
        case .waiting: accent
        case .download: get
        }
    }
}

/// The phase bar and legend under the inspector header. Without phase times it shows the total only.
struct TimingSummary: View {
    let timing: HTTPTiming?
    let total: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    if let timing, timing.total > 0 {
                        let phases = timing.phases.filter { $0.duration > 0 }
                        let available = proxy.size.width - CGFloat(max(phases.count - 1, 0)) * 2
                        ForEach(phases, id: \.phase) { item in
                            Rectangle()
                                .fill(Theme.color(for: item.phase))
                                .frame(width: max(2, available * item.duration / timing.total))
                        }
                    } else {
                        Rectangle().fill(Theme.accent)
                    }
                }
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            FlowLayout(spacing: 12, lineSpacing: 4) {
                if let timing {
                    let phases = timing.phases
                    ForEach(Array(phases.enumerated()), id: \.offset) { index, item in
                        legend(item.phase.rawValue, Self.milliseconds(item.duration) + (index == phases.count - 1 ? " ms" : ""),
                               color: Theme.color(for: item.phase))
                    }
                } else {
                    legend("Total", Formatting.duration(total), color: Theme.accent)
                }
            }
        }
    }

    private func legend(_ name: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text("\(name) \(value)").monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .fixedSize()
    }

    static func milliseconds(_ seconds: TimeInterval) -> String {
        let ms = seconds * 1000
        if ms >= 1 || ms == 0 { return String(Int(ms.rounded())) }
        return String(format: "%.1f", ms)
    }
}

/// The Timing tab: each phase as a row with its own bar, offset where it started.
struct TimingDetail: View {
    let exchange: HTTPExchange

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let timing = exchange.timing {
                    let total = max(timing.total, 0.000_001)
                    let phases = timing.phases
                    let starts = Self.starts(phases.map(\.duration))
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                        ForEach(Array(phases.enumerated()), id: \.offset) { index, item in
                            let start = starts[index]
                            GridRow {
                                Text(item.phase.rawValue)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .leading)
                                GeometryReader { proxy in
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(Theme.color(for: item.phase))
                                        .frame(width: max(3, proxy.size.width * item.duration / total))
                                        .offset(x: proxy.size.width * start / total)
                                }
                                .frame(height: 8)
                                Text(Formatting.duration(item.duration))
                                    .font(.system(size: 12))
                                    .monospacedDigit()
                                    .frame(width: 64, alignment: .trailing)
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Text("Upstream total").foregroundStyle(.secondary)
                        Spacer()
                        Text(Formatting.duration(timing.total)).monospacedDigit().fontWeight(.semibold)
                    }
                    .font(.system(size: 12))
                    if exchange.duration > timing.total + 0.005 {
                        Text("The whole exchange took \(Formatting.duration(exchange.duration)), including reading the request from the app\(exchange.breakpoint == nil ? "" : " and time paused at breakpoints").")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("Took \(Formatting.duration(exchange.duration)) in total. A phase breakdown is recorded for requests the proxy sends upstream; this one didn't get that far or was captured by an older version.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text("Started \(exchange.startedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
        }
    }

    /// Where each phase begins, as the sum of the ones before it.
    static func starts(_ durations: [TimeInterval]) -> [TimeInterval] {
        var running: TimeInterval = 0
        return durations.map { duration in
            defer { running += duration }
            return running
        }
    }
}

// MARK: Body

/// A body or payload with a small bar (format tag, size, Tree / Hex / Copy) above line-numbered code.
struct BodyPanel: View {
    let bytes: [UInt8]
    let contentType: String?
    var emptyText = "No body"
    @State private var mode = Mode.formatted

    enum Mode { case formatted, tree, hex }

    var body: some View {
        let presentation = Formatting.present(bytes, contentType: contentType)
        VStack(alignment: .leading, spacing: 0) {
            if case .empty = presentation {
                Text(emptyText).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 8) {
                    Text(tag(presentation))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(height: 19)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text(detail(presentation))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if case .json = presentation {
                        Button("Tree") { mode = mode == .tree ? .formatted : .tree }
                            .buttonStyle(MiniButtonStyle(selected: mode == .tree))
                    }
                    if !isBinary(presentation) {
                        Button("Hex") { mode = mode == .hex ? .formatted : .hex }
                            .buttonStyle(MiniButtonStyle(selected: mode == .hex))
                    }
                    Button("Copy") { copyToPasteboard(copyText(presentation)) }
                        .buttonStyle(MiniButtonStyle())
                        .help(mode == .hex ? "Copy the hex dump" : "Copy the body")
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 2)

                switch (mode, presentation) {
                case (.tree, .json):
                    JSONTreeView(bytes: bytes)
                case (.hex, _):
                    CodeText(text: Formatting.hexDump(Array(bytes.prefix(1_000_000))))
                case (_, .json(let text)):
                    CodeText(text: text, highlightJSON: true)
                case (_, .text(let text)):
                    CodeText(text: text)
                case (_, .binary(let dump)):
                    CodeText(text: dump)
                case (_, .empty):
                    EmptyView()
                }
            }
        }
    }

    private func isBinary(_ presentation: BodyPresentation) -> Bool {
        if case .binary = presentation { return true }
        return false
    }

    private func tag(_ presentation: BodyPresentation) -> String {
        switch presentation {
        case .empty: "EMPTY"
        case .json: "JSON"
        case .text: "TEXT"
        case .binary: "HEX"
        }
    }

    private func detail(_ presentation: BodyPresentation) -> String {
        let size = "\(bytes.count.formatted()) byte\(bytes.count == 1 ? "" : "s")"
        switch (mode, presentation) {
        case (.hex, _): return "\(size) · hex"
        case (.tree, _): return "\(size) · tree"
        case (_, .json): return "\(size) · pretty"
        case (_, .binary): return "\(size) · binary"
        default: return size
        }
    }

    private func copyText(_ presentation: BodyPresentation) -> String {
        if mode == .hex { return Formatting.hexDump(bytes) }
        switch presentation {
        case .empty: return ""
        case .json(let text), .text(let text): return text
        case .binary(let dump): return dump
        }
    }
}

/// JSON as an expandable outline, keys in document order.
struct JSONTreeView: View {
    let bytes: [UInt8]

    var body: some View {
        if let root = JSONTreeNode.parse(bytes) {
            List {
                OutlineGroup(root.children ?? [root], children: \.children) { node in
                    HStack(spacing: 6) {
                        if let key = node.key {
                            Text(key).foregroundStyle(Theme.get)
                            Text(":").foregroundStyle(.tertiary)
                        }
                        Text(node.value)
                            .foregroundStyle(color(node.kind))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } else {
            Text("Not valid JSON").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func color(_ kind: JSONTreeNode.Kind) -> Color {
        switch kind {
        case .object, .array: .secondary
        case .string: Theme.post
        case .number: Theme.put
        case .literal: Theme.mqtt
        }
    }
}
#endif

#if os(macOS)
/// The segmented control from the mockups: a quiet track with the chosen segment raised.
struct PillSegments<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isOn = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.raised)
                                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension Theme {
    /// The raised surface of a selected segment: white in light mode, the window's darkest gray in dark mode.
    static let raised = Color(light: 0xFFFFFF, dark: 0x15181C)
}
#endif
