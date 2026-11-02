#if os(macOS)
import AppCore
import ProxyCore
import SwiftUI

/// The header editor in the breakpoint and Map Local sheets. It opens as a table of name and value
/// rows that can be added, removed and switched off (duplicate names are fine, as on the wire), with
/// a Raw view of the same rows as text. Both views edit `rows`, so switching never loses anything.
struct HeaderEditor: View {
    @Binding var rows: [EditableHeader]
    var label = "Headers"

    enum Mode: String { case table, raw }
    /// Remembered across sheets, so someone who prefers text gets text next time.
    @AppStorage("headerEditorMode") private var mode: Mode = .table
    @State private var rawText = ""
    @FocusState private var focus: Field?

    enum Field: Hashable { case name(UUID), value(UUID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                CapsLabel(label)
                Text(countText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer(minLength: 8)
                modeButton(.table, title: "Table", help: "Edit the headers as rows")
                modeButton(.raw, title: "Raw", help: "Edit the headers as text, one per line")
            }
            switch mode {
            case .table: table
            case .raw: raw
            }
        }
        .onAppear { if mode == .raw { rawText = HeaderText.format(rows) } }
        .onChange(of: mode) { if mode == .raw { rawText = HeaderText.format(rows) } }
        .onChange(of: rows) {
            // Rows changed from outside the text (a new paused exchange, say): show them.
            if mode == .raw, HeaderText.parseRows(rawText, reusing: rows) != rows { rawText = HeaderText.format(rows) }
        }
    }

    private var countText: String {
        let sent = EditableHeader.sent(rows).count
        let off = rows.filter { !$0.isEnabled && !$0.name.isEmpty }.count
        return off == 0 ? "\(sent)" : "\(sent) · \(off) off"
    }

    private func modeButton(_ value: Mode, title: String, help: String) -> some View {
        Button(title) { mode = value }
            .buttonStyle(MiniButtonStyle(selected: mode == value))
            .help(help)
            .accessibilityAddTraits(mode == value ? .isSelected : [])
    }

    // MARK: Table

    private var table: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(spacing: 0) {
                    if rows.isEmpty {
                        Text("No headers")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    ForEach($rows) { $row in
                        HeaderRowView(row: $row, focus: $focus,
                                      onSubmitValue: { if row.id == rows.last?.id { addRow() } },
                                      onRemove: { remove(row.id) })
                        if row.id != rows.last?.id {
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))

            Button(action: addRow) {
                Label("Add header", systemImage: "plus")
            }
            .buttonStyle(MiniButtonStyle())
            .help("Add a header row")
        }
    }

    private func addRow() {
        let row = EditableHeader(name: "", value: "")
        rows.append(row)
        focus = .name(row.id)
    }

    private func remove(_ id: UUID) {
        rows.removeAll { $0.id == id }
    }

    // MARK: Raw

    private var raw: some View {
        VStack(alignment: .leading, spacing: 6) {
            CodeEditor(text: $rawText, fontSize: 12)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                .onChange(of: rawText) {
                    guard mode == .raw else { return }
                    let parsed = HeaderText.parseRows(rawText, reusing: rows)
                    if parsed != rows { rows = parsed }
                }
            Text("Name: value, one per line. Start a line with // to switch it off.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One header in the table: on/off, name, value and a remove button that shows on hover.
private struct HeaderRowView: View {
    @Binding var row: EditableHeader
    var focus: FocusState<HeaderEditor.Field?>.Binding
    var onSubmitValue: () -> Void
    var onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                row.isEnabled.toggle()
            } label: {
                Image(systemName: row.isEnabled ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(row.isEnabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.isEnabled ? "Switch this header off without deleting it" : "Switch this header back on")
            .accessibilityLabel(row.isEnabled ? "Enabled" : "Disabled")

            TextField("Name", text: $row.name, prompt: Text("Name"))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .focused(focus, equals: .name(row.id))
                .onSubmit { focus.wrappedValue = .value(row.id) }
                .frame(width: 112, alignment: .leading)

            TextField("Value", text: $row.value, prompt: Text("Value"))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .focused(focus, equals: .value(row.id))
                .onSubmit(onSubmitValue)

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .help("Remove this header")
            .accessibilityLabel("Remove header")
        }
        .opacity(row.isEnabled ? 1 : 0.5)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(minHeight: 28)
        .background(isHovered ? Theme.fill : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
#endif
