#if os(macOS)
import AppKit
import ObjectiveC
import SwiftUI

/// How a SwiftUI Table or List draws its selected rows. SwiftUI always uses the system accent there, so this
/// reaches the NSTableView underneath and draws the mockup's teal selection instead.
enum RowSelectionStyle {
    /// Timeline rows: a light teal wash across the row with a 2 pt teal bar on the leading edge.
    case timeline
    /// Sidebar and topic rows: a rounded light teal wash.
    case rounded

    /// The wash, which matches the mockup's `--w-sel`: 14 % accent in dark mode, 10 % in light mode.
    static func wash(dark: Bool) -> NSColor {
        NSColor(Theme.accent).withAlphaComponent(dark ? 0.14 : 0.10)
    }
}

/// Put in a `.background` of a Table or List. It finds that view's NSTableView, styles its selection, and,
/// when `followsEnd` is on, keeps the newest row in view while the list is scrolled to the bottom.
struct TableHook: NSViewRepresentable {
    var selection: RowSelectionStyle
    var followsEnd = false
    var rowCount = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.attach(from: view, style: selection) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            if coordinator.table == nil { coordinator.attach(from: view, style: selection) }
            if let table = coordinator.table { TealSelection.install(on: table, style: selection) }
            coordinator.rowCountChanged(to: rowCount, follow: followsEnd)
        }
    }

    @MainActor
    final class Coordinator {
        weak var table: NSTableView?
        private var lastCount = 0
        private var atBottom = true
        private var observer: NSObjectProtocol?

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func attach(from anchor: NSView, style: RowSelectionStyle) {
            guard let table = Self.findTable(near: anchor) else { return }
            self.table = table
            TealSelection.install(on: table, style: style)
            if let clip = table.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                                  queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateAtBottom() }
                }
            }
        }

        func rowCountChanged(to count: Int, follow: Bool) {
            defer { lastCount = count }
            guard let table else { return }
            TealSelection.patchVisibleRows(of: table)
            // Follow new rows only while the list is already at its end, so reading older rows isn't interrupted.
            guard follow, count > lastCount, atBottom, table.numberOfRows > 0 else { return }
            table.scrollRowToVisible(table.numberOfRows - 1)
        }

        private func updateAtBottom() {
            guard let table, let clip = table.enclosingScrollView?.contentView else { return }
            let slack = max(table.rowHeight, 24) * 1.5
            atBottom = clip.bounds.maxY >= table.frame.height - slack
        }

        /// The NSTableView whose scroll view sits where `anchor` (a background of the Table or List) is drawn.
        /// Falls back to the first table under the nearest ancestor that has one.
        static func findTable(near anchor: NSView) -> NSTableView? {
            if let root = anchor.window?.contentView?.superview ?? anchor.window?.contentView {
                let center = anchor.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil)
                var tables: [NSTableView] = []
                collectTables(in: root, into: &tables)
                if let match = tables.first(where: { table in
                    let host: NSView = table.enclosingScrollView ?? table
                    return host.convert(host.bounds, to: nil).contains(center)
                }) {
                    return match
                }
            }
            var ancestor = anchor.superview
            while let current = ancestor {
                var tables: [NSTableView] = []
                collectTables(in: current, into: &tables)
                if let first = tables.first { return first }
                ancestor = current.superview
            }
            return nil
        }

        private static func collectTables(in view: NSView, into tables: inout [NSTableView]) {
            if let table = view as? NSTableView {
                tables.append(table)
                return
            }
            for subview in view.subviews { collectTables(in: subview, into: &tables) }
        }
    }
}

/// Replaces `drawSelection(in:)` and `interiorBackgroundStyle` on the row view classes of the tables it is
/// installed on. Tables that weren't marked keep the system drawing.
@MainActor
enum TealSelection {
    private static var styleKey: UInt8 = 0
    private static var patched = Set<ObjectIdentifier>()

    static func install(on table: NSTableView, style: RowSelectionStyle) {
        objc_setAssociatedObject(table, &styleKey, NSNumber(value: style == .timeline ? 1 : 2), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // A source list draws its selection with a material view, not drawSelection(in:), so switch it to the
        // regular style, which does call it.
        if table.selectionHighlightStyle == .sourceList { table.selectionHighlightStyle = .regular }
        patchVisibleRows(of: table)
    }

    static func patchVisibleRows(of table: NSTableView) {
        table.enumerateAvailableRowViews { rowView, _ in
            patch(type(of: rowView))
            rowView.needsDisplay = true
        }
    }

    static func style(of rowView: NSTableRowView) -> RowSelectionStyle? {
        var view: NSView? = rowView.superview
        while let current = view, !(current is NSTableView) { view = current.superview }
        guard let table = view, let value = objc_getAssociatedObject(table, &styleKey) as? NSNumber else { return nil }
        return value.intValue == 1 ? .timeline : .rounded
    }

    private static func patch(_ rowClass: NSTableRowView.Type) {
        let id = ObjectIdentifier(rowClass)
        guard !patched.contains(id) else { return }
        patched.insert(id)

        // drawSelection(in:)
        let drawSelector = #selector(NSTableRowView.drawSelection(in:))
        if let method = class_getInstanceMethod(rowClass, drawSelector) {
            typealias Draw = @convention(c) (NSTableRowView, Selector, NSRect) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Draw.self)
            let block: @convention(block) (NSTableRowView, NSRect) -> Void = { rowView, dirty in
                guard let style = MainActor.assumeIsolated({ TealSelection.style(of: rowView) }) else {
                    original(rowView, drawSelector, dirty)
                    return
                }
                MainActor.assumeIsolated { TealSelection.draw(rowView, style: style) }
            }
            override(rowClass, selector: drawSelector, method: method, with: imp_implementationWithBlock(block))
        }

        // interiorBackgroundStyle: keep cell text in its normal colors on the light teal wash.
        let styleSelector = #selector(getter: NSTableRowView.interiorBackgroundStyle)
        if let method = class_getInstanceMethod(rowClass, styleSelector) {
            typealias Getter = @convention(c) (NSTableRowView, Selector) -> NSView.BackgroundStyle
            let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            let block: @convention(block) (NSTableRowView) -> NSView.BackgroundStyle = { rowView in
                if MainActor.assumeIsolated({ TealSelection.style(of: rowView) }) != nil { return .normal }
                return original(rowView, styleSelector)
            }
            override(rowClass, selector: styleSelector, method: method, with: imp_implementationWithBlock(block))
        }
    }

    /// Adds the override to the class itself, so superclasses (and every other row view) are left alone.
    private static func override(_ cls: AnyClass, selector: Selector, method: Method, with imp: IMP) {
        if !class_addMethod(cls, selector, imp, method_getTypeEncoding(method)) {
            method_setImplementation(method, imp)
        }
    }

    private static func draw(_ rowView: NSTableRowView, style: RowSelectionStyle) {
        let dark = rowView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        switch style {
        case .timeline:
            RowSelectionStyle.wash(dark: dark).setFill()
            rowView.bounds.fill(using: .sourceOver)
            NSColor(Theme.accent).setFill()
            NSRect(x: 0, y: 0, width: 2, height: rowView.bounds.height).fill()
        case .rounded:
            RowSelectionStyle.wash(dark: dark).setFill()
            NSBezierPath(roundedRect: rowView.bounds.insetBy(dx: 10, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
    }
}
#endif
