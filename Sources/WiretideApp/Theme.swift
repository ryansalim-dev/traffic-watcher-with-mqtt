#if os(macOS)
import AppCore
import AppKit
import SwiftUI

/// Wiretide's colors, type and spacing. Every view takes its styling from here, so the look can be
/// tuned in one place. Colors come in light and dark pairs and follow the window's appearance.
enum Theme {
    // MARK: Brand

    /// Tide teal, the one accent color.
    static let accent = Color(light: 0x0B8D87, dark: 0x4FD1C5)
    /// Text and icons drawn on top of the accent color.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x06201E)

    // MARK: Meaning

    static let get = Color(light: 0x1F6FD6, dark: 0x6CB4FF)
    static let post = Color(light: 0x12935A, dark: 0x4CD995)
    static let put = Color(light: 0xB7720B, dark: 0xF5B74A)
    static let delete = Color(light: 0xD43F3F, dark: 0xFF7A7A)
    static let mqtt = Color(light: 0x7A4FD6, dark: 0xB893FF)
    static let webSocket = Color(light: 0x0F8EA0, dark: 0x5FD6E8)
    static let neutral = Color(light: 0x6B757C, dark: 0x7D8890)

    static let success = Color(light: 0x12935A, dark: 0x4CD995)
    static let redirect = Color(light: 0x4F6F92, dark: 0x8FB3D9)
    static let warning = Color(light: 0xB7720B, dark: 0xF5B74A)
    static let failure = Color(light: 0xD43F3F, dark: 0xFF6B6B)

    // MARK: Surfaces

    // The graphite palette from the approved mockups, used instead of the system's neutral grays.
    /// The timeline and topic list.
    static let canvas = Color(light: 0xFFFFFF, dark: 0x15181C)
    /// The sidebar column.
    static let sidebar = Color(light: 0xEEF0F2, dark: 0x1B1F24)
    /// The toolbar strip and sheet footers.
    static let bar = Color(light: 0xF7F8F9, dark: 0x1A1D22)
    /// The inspector column and sheets.
    static let panel = Color(light: 0xFAFBFB, dark: 0x171A1F)

    /// A quiet fill for capsules, fields and cards.
    static let fill = Color(light: 0x000000, lightOpacity: 0.05, dark: 0xFFFFFF, darkOpacity: 0.06)
    static let hairline = Color(light: 0x000000, lightOpacity: 0.08, dark: 0xFFFFFF, darkOpacity: 0.07)

    // MARK: Type

    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let pillFont = Font.system(size: 10.5, weight: .semibold, design: .monospaced)
    static let label = Font.system(size: 10.5, weight: .semibold)

    // MARK: Spacing (4 pt grid)

    static let controlRadius: CGFloat = 7
    static let cardRadius: CGFloat = 12

    // MARK: Lookups

    static func color(forPill pill: String, kind: TrafficRow.Kind) -> Color {
        switch kind {
        case .mqtt: return mqtt
        case .webSocket: return webSocket
        case .tunnel: return neutral
        case .tls: return failure
        case .http:
            switch pill {
            case "GET", "HEAD", "OPTIONS": return get
            case "POST": return post
            case "PUT", "PATCH": return put
            case "DELETE": return delete
            default: return neutral
            }
        }
    }

    static func color(for tone: RowTone) -> Color {
        switch tone {
        case .success: success
        case .redirect: redirect
        case .clientError: warning
        case .failure: failure
        case .mqtt: mqtt
        case .webSocket: webSocket
        case .neutral: neutral
        }
    }

    static func color(forStatus code: Int?) -> Color {
        switch code ?? 0 {
        case 200..<300: success
        case 300..<400: redirect
        case 400..<500: warning
        default: failure
        }
    }

    /// A stable color for a host's monogram tile.
    static func monogramColor(for host: String) -> Color {
        let palette: [UInt32] = [0x2F7FD6, 0xC46A2B, 0x3A9A6A, 0x8A5BD6, 0x0F8EA0, 0xB8476A, 0x6B7FD6]
        let sum = host.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hex: palette[sum % palette.count])
    }
}

/// Timeline row height: 30 pt by default, 24 pt in compact mode (View menu).
enum RowDensity: String, CaseIterable, Identifiable {
    case regular, compact

    static let storageKey = "rowDensity"
    var id: String { rawValue }
    var title: String { self == .regular ? "Regular Rows" : "Compact Rows" }
    /// Height of a cell's content; the table adds its own padding around it.
    var contentHeight: CGFloat { self == .regular ? 22 : 16 }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// A color that switches with the appearance it is drawn in.
    init(light: UInt32, lightOpacity: Double = 1, dark: UInt32, darkOpacity: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: isDark ? darkOpacity : lightOpacity)
        })
    }
}

// MARK: Shared pieces

/// The fixed-width method or packet-type pill used in the timeline and inspector headers.
struct TypePill: View {
    let text: String
    let color: Color
    var fixedWidth: CGFloat? = 62

    var body: some View {
        Text(text)
            .font(Theme.pillFont)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, fixedWidth == nil ? 7 : 2)
            .padding(.vertical, 3)
            .frame(width: fixedWidth)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// A small filled circle with a soft halo, for live and status indicators.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7
    var halo = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                if halo { Circle().fill(color.opacity(0.22)).frame(width: size + 6, height: size + 6) }
            }
    }
}

/// A line chart of counts with a soft area fill, sized by its frame.
struct Sparkline: View {
    let values: [Int]
    var color: Color = Theme.accent
    var filled = true

    var body: some View {
        GeometryReader { proxy in
            let points = Self.points(values, in: proxy.size)
            ZStack {
                if filled, let first = points.first, let last = points.last {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: proxy.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: last.x, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(0.14))
                }
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }

    static func points(_ values: [Int], in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let peak = CGFloat(max(values.max() ?? 1, 1))
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            CGPoint(x: CGFloat(index) * step, y: size.height - 2 - CGFloat(value) / peak * (size.height - 4))
        }
    }
}

/// Uppercase section label used in the inspector and setup screen.
struct CapsLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.label)
            .kerning(0.6)
            .foregroundStyle(.tertiary)
    }
}
#endif
