import AppKit

/// Menu bar only: no Dock icon, no main window (LSUIElement in Info.plist does the same for the .app).
@main
enum ClaudeUsageBarApp {
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate  // NSApplication keeps only a weak reference
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
