#if os(macOS)
import AppKit
import SwiftUI

// Wiretide's one dropdown design. Every pop-up choice and every "+ Add…" menu in the app is drawn
// here, instead of with the stock Picker and Menu styles, so they share one height, one box and one
// chevron, and line up with BoxedTextField and the other graphite controls.
//
// The trigger is a SwiftUI button drawn to the theme; the list it opens is a real NSMenu, so the
// open menu keeps the system's keyboard navigation, type-to-select, submenus and VoiceOver. To
// assistive apps the control is presented as a stock Picker or Menu (accessibilityRepresentation).

/// How tall a dropdown is. Fields match BoxedTextField; compact matches chips and segments.
enum DropdownSize {
    /// 28 pt, for forms and editor fields, next to BoxedTextField.
    case field
    /// 24 pt, for bars, cards and footers, next to filter chips and PillSegments.
    case compact

    var height: CGFloat { self == .field ? 28 : 24 }
    var fontSize: CGFloat { self == .field ? 12.5 : 12 }
    var horizontalPadding: CGFloat { self == .field ? 9 : 8 }
}

/// Boxed draws the quiet field box at rest (choices); plain only shows it on hover (actions).
enum DropdownStyle {
    case boxed, plain
}

/// One entry in a dropdown's menu.
struct DropdownItem {
    enum Kind {
        case action(() -> Void)
        case submenu([DropdownItem])
        case header
        case divider
    }

    var title: String
    var kind: Kind
    var isEnabled = true
    var isChecked = false

    static func button(_ title: String, checked: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> DropdownItem {
        DropdownItem(title: title, kind: .action(action), isEnabled: enabled, isChecked: checked)
    }

    static func submenu(_ title: String, checked: Bool = false, _ items: [DropdownItem]) -> DropdownItem {
        DropdownItem(title: title, kind: .submenu(items), isChecked: checked)
    }

    /// A small gray title over the items that follow it.
    static func header(_ title: String) -> DropdownItem {
        DropdownItem(title: title, kind: .header)
    }

    static var divider: DropdownItem { DropdownItem(title: "", kind: .divider) }
}

// MARK: Choice

/// A pop-up choice of one value, in place of `Picker(...).pickerStyle(.menu)`.
/// Give it a width with `.frame(width:)`, or `.fixedSize()` to fit the longest title shown.
struct Dropdown<Value: Hashable>: View {
    /// Read by VoiceOver and shown as the tooltip; the control itself only shows the value.
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var size: DropdownSize = .field
    var monospaced = false

    var body: some View {
        DropdownControl(size: size, style: .boxed, indicator: "chevron.up.chevron.down", fillsWidth: true,
                        monospacedItems: monospaced, items: items) {
            Text(options.first { $0.value == selection }?.title ?? "")
                .font(.system(size: size.fontSize, design: monospaced ? .monospaced : .default))
                .foregroundStyle(.primary)
        }
        .help(title)
        .accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].title).tag(options[index].value)
                }
            }
        }
    }

    private func items() -> [DropdownItem] {
        options.map { option -> DropdownItem in
            .button(option.title, checked: option.value == selection) { selection = option.value }
        }
    }
}

// MARK: Action menu

/// A button that opens a menu of actions ("+ Add Rule", "Export"), in place of a stock `Menu`.
struct DropdownMenu: View {
    let title: String
    var systemImage: String?
    var size: DropdownSize = .compact
    var style: DropdownStyle = .plain
    /// Built when the menu opens, so it always reflects the current state.
    let items: () -> [DropdownItem]

    init(_ title: String, systemImage: String? = nil, size: DropdownSize = .compact, style: DropdownStyle = .plain,
         items: @escaping () -> [DropdownItem]) {
        self.title = title
        self.systemImage = systemImage
        self.size = size
        self.style = style
        self.items = items
    }

    var body: some View {
        DropdownControl(size: size, style: style, indicator: "chevron.down", fillsWidth: false, monospacedItems: false, items: items) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: size.fontSize - 1, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text(title)
                    .font(.system(size: size.fontSize, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
        .fixedSize()
        .accessibilityRepresentation {
            Menu(title) { DropdownAccessibleItems(items: items()) }
        }
    }
}

// MARK: Shared trigger

private struct DropdownControl<Label: View>: View {
    let size: DropdownSize
    let style: DropdownStyle
    let indicator: String
    let fillsWidth: Bool
    let monospacedItems: Bool
    let items: () -> [DropdownItem]
    @ViewBuilder let label: Label

    @State private var anchor = DropdownAnchor()
    @State private var isOpen = false
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous) }
    private var isActive: Bool { isOpen || isFocused }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                label
                    .lineLimit(1)
                    .truncationMode(.tail)
                if fillsWidth { Spacer(minLength: 2) }
                Image(systemName: indicator)
                    .font(.system(size: size == .field ? 9 : 8.5, weight: .bold))
                    .foregroundStyle(isActive ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, size.horizontalPadding)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .frame(height: size.height)
            .background(background, in: shape)
            .overlay { shape.strokeBorder(border, lineWidth: isActive ? 1 : 0.5) }
            .shadow(color: isActive ? Theme.accent.opacity(0.3) : .clear, radius: 3)
            .contentShape(shape)
            .background(DropdownAnchorView(anchor: anchor))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { isHovered = $0 && isEnabled }
        .onKeyPress(keys: [.downArrow, .upArrow]) { _ in
            open()
            return .handled
        }
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private var background: Color {
        switch style {
        case .boxed: isHovered || isOpen ? Theme.fillStrong : Theme.fill
        case .plain: isOpen ? Theme.accent.opacity(0.12) : isHovered ? Theme.fill : .clear
        }
    }

    private var border: Color {
        if isActive { return Theme.accent }
        return style == .boxed || isHovered ? Theme.hairline : .clear
    }

    private func open() {
        guard isEnabled, !isOpen, let view = anchor.view else { return }
        let menu = DropdownItem.menu(items(), monospaced: monospacedItems, fontSize: size.fontSize + 0.5)
        menu.minimumWidth = view.bounds.width
        isOpen = true
        // Let the open state draw before the menu takes over the run loop; popUp returns when it closes.
        Task { @MainActor in
            // Just under the control, lined up with its leading edge.
            let below = NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4)
            menu.popUp(positioning: nil, at: below, in: view)
            isOpen = false
        }
    }
}

// MARK: NSMenu

extension DropdownItem {
    @MainActor
    static func menu(_ items: [DropdownItem], monospaced: Bool, fontSize: CGFloat) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.font = .menuFont(ofSize: fontSize)
        for item in items {
            menu.addItem(item.menuItem(monospaced: monospaced, fontSize: fontSize))
        }
        return menu
    }

    @MainActor
    private func menuItem(monospaced: Bool, fontSize: CGFloat) -> NSMenuItem {
        let item: NSMenuItem
        switch kind {
        case .divider:
            return .separator()
        case .header:
            return .sectionHeader(title: title)
        case .submenu(let children):
            item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = Self.menu(children, monospaced: monospaced, fontSize: fontSize)
        case .action(let handler):
            let target = DropdownMenuTarget(handler)
            item = NSMenuItem(title: title, action: #selector(DropdownMenuTarget.fire(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = target // NSMenuItem holds its target weakly.
        }
        if monospaced {
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            ])
        }
        item.isEnabled = isEnabled
        item.state = isChecked ? .on : .off
        return item
    }
}

@MainActor
private final class DropdownMenuTarget: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire(_ sender: Any?) { handler() }
}

/// Holds the NSView behind a dropdown, so the menu can open from its frame.
@MainActor
private final class DropdownAnchor {
    weak var view: NSView?
}

private struct DropdownAnchorView: NSViewRepresentable {
    let anchor: DropdownAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    /// Never takes clicks, so they reach the SwiftUI button on top.
    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The menu as SwiftUI content, for the accessibility representation.
private struct DropdownAccessibleItems: View {
    let items: [DropdownItem]

    var body: some View {
        ForEach(items.indices, id: \.self) { index in
            let item = items[index]
            switch item.kind {
            case .action(let handler):
                Button(item.title, action: handler).disabled(!item.isEnabled)
            case .submenu(let children):
                Menu(item.title) { DropdownAccessibleItems(items: children) }
            case .header:
                Text(item.title)
            case .divider:
                Divider()
            }
        }
    }
}
#endif
