import Foundation
import ServiceManagement
import UsageCore

/// "Launch at login" via SMAppService (macOS 13+). Only works when running as the .app bundle.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("launch at login: \(error)")
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Like the Windows widget, start with the computer from the first run on; the user can turn it off.
    func enableOnFirstRun() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UserDefaults.standard.set(true, forKey: key)
        setEnabled(true)
    }
}
