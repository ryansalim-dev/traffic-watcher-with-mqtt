import Foundation

/// What the main window's toolbar shows at a given width of the content column, so its items never overlap.
///
/// The recording capsule and the filter field share what's left after the fixed buttons. Parts are dropped
/// in a set order as the column narrows: first the field shrinks to its minimum, then the sparkline goes,
/// then the "Recording" label, then the event count, then the field folds into a search button, and last
/// the timer goes and the Packets/Topics switch narrows.
public struct ToolbarFit: Equatable, Sendable {
    public var showsTimer = true
    public var showsRecordingLabel = true
    public var showsSparkline = true
    public var showsCount = true
    /// nil folds the field into a button that opens it in a popover.
    public var searchWidth: Double? = ToolbarFit.searchWidest
    /// A narrower Packets/Topics switch, for the narrowest MQTT column.
    public var compactModeSwitch = false

    public static let searchWidest: Double = 220
    public static let searchNarrowest: Double = 150
    public static let modeSwitchWidth: Double = 150
    public static let compactModeSwitchWidth: Double = 120

    // Widths in points, measured from the app's screenshots at its 12.5 pt toolbar font, rounded up.
    static let button: Double = 36   // badged buttons (rule and script counts) run a little wider
    /// Space between toolbar items and at the toolbar's ends, plus slack so items never touch.
    static let spacing: Double = 48
    static let modeSwitch: Double = modeSwitchWidth + 16
    static let searchButton: Double = 34
    static let capsuleBase: Double = 36       // the stop button
    static let timer: Double = 48
    static let recordingLabel: Double = 83
    static let sparkline: Double = 65
    static let count: Double = 84
    static let fullSlack: Double = 80

    public init(showsTimer: Bool = true, showsRecordingLabel: Bool = true, showsSparkline: Bool = true, showsCount: Bool = true,
                searchWidth: Double? = ToolbarFit.searchWidest, compactModeSwitch: Bool = false) {
        self.showsTimer = showsTimer
        self.showsRecordingLabel = showsRecordingLabel
        self.showsSparkline = showsSparkline
        self.showsCount = showsCount
        self.searchWidth = searchWidth
        self.compactModeSwitch = compactModeSwitch
    }

    /// - Parameters:
    ///   - width: the content column's width, which its part of the toolbar spans.
    ///   - buttons: icon buttons in that part, the sidebar toggle included.
    ///   - showsModeSwitch: whether the Packets/Topics switch sits in the middle.
    public static func fitting(width: Double, buttons: Int, showsModeSwitch: Bool) -> ToolbarFit {
        var room = width - Double(buttons) * button - spacing - (showsModeSwitch ? modeSwitch : 0) - capsuleBase
        var fit = ToolbarFit(showsTimer: false, showsRecordingLabel: false, showsSparkline: false, showsCount: false,
                             searchWidth: nil)
        // Too narrow even for the timer and a search button: the switch gives up some width first.
        if showsModeSwitch && room < searchButton + timer {
            fit.compactModeSwitch = true
            room += modeSwitchWidth - compactModeSwitchWidth
        }
        room -= searchButton
        // Each part is added only while everything before it fits, so nothing comes back as the column narrows.
        guard room >= timer else { return fit }
        fit.showsTimer = true
        room -= timer
        guard room + searchButton >= searchNarrowest else { return fit }
        room += searchButton - searchNarrowest
        fit.searchWidth = searchNarrowest
        guard room >= count else { return fit }
        fit.showsCount = true
        room -= count
        guard room >= recordingLabel else { return fit }
        fit.showsRecordingLabel = true
        room -= recordingLabel
        guard room >= sparkline else { return fit }
        fit.showsSparkline = true
        room -= sparkline
        // Every part showing means more gaps between items than `spacing` covers, so some room stays unused.
        fit.searchWidth = min(searchWidest, searchNarrowest + max(0, room - fullSlack))
        return fit
    }
}
