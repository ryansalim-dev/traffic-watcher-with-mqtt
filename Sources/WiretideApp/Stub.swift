#if !os(macOS)
// The app's views use SwiftUI and AppKit, so on other platforms the executable only explains that.
@main
enum WiretideStub {
    static func main() {
        print("Wiretide's user interface runs on macOS. The capture engine libraries work everywhere.")
    }
}
#endif
