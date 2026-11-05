import Foundation

/// What the main window's toolbar shows at a given width of the content column, so its items never overlap.
///
/// The recording capsule and the filter field share what's left after the fixed buttons. Parts are dropped
/// in a set order as the column narrows: first the field shrinks to its minimum, then the sparkline goes,
/// then the "Recording" label, then the event count, and last the field folds into a search button.
public struct ToolbarFit: Equatable, Sendable {
    public var showsRecordingLabel = true
    public var showsSparkline = true
    public var showsCount = true
    /// nil folds the field into a button that opens it in a popover.
    public var searchWidth: Double? = ToolbarFit.searchWidest

    public static let searchWidest: Double = 220
    public static let searchNarrowest: Double = 150

    // Rough widths in points, measured from the app at its 12.5 pt toolbar font.
    static let button: Double = 38
    /// Space between toolbar items and at the toolbar's ends, plus a little slack so items never touch.
    static let spacing: Double = 48
    static let modeSwitch: Double = 166
    static let capsuleBase: Double = 84        // stop button and timer
    static let recordingLabel: Double = 83
    static let sparkline: Double = 65
    static let count: Double = 84

    public init(showsRecordingLabel: Bool = true, showsSparkline: Bool = true, showsCount: Bool = true,
                searchWidth: Double? = ToolbarFit.searchWidest) {
        self.showsRecordingLabel = showsRecordingLabel
        self.showsSparkline = showsSparkline
        self.showsCount = showsCount
        self.searchWidth = searchWidth
    }

    /// - Parameters:
    ///   - width: the content column's width, which its part of the toolbar spans.
    ///   - buttons: icon buttons in that part, the sidebar toggle included.
    ///   - showsModeSwitch: whether the Packets/Topics switch sits in the middle.
    public static func fitting(width: Double, buttons: Int, showsModeSwitch: Bool) -> ToolbarFit {
        var room = width - Double(buttons) * button - spacing - (showsModeSwitch ? modeSwitch : 0) - capsuleBase
        var fit = ToolbarFit(showsRecordingLabel: false, showsSparkline: false, showsCount: false, searchWidth: nil)
        // Each part is added only while everything before it fits, so nothing comes back as the column narrows.
        guard room >= searchNarrowest else { return fit }
        fit.searchWidth = searchNarrowest
        room -= searchNarrowest
        guard room >= count else { return fit }
        fit.showsCount = true
        room -= count
        guard room >= recordingLabel else { return fit }
        fit.showsRecordingLabel = true
        room -= recordingLabel
        guard room >= sparkline else { return fit }
        fit.showsSparkline = true
        room -= sparkline
        fit.searchWidth = min(searchWidest, searchNarrowest + room)
        return fit
    }
}
