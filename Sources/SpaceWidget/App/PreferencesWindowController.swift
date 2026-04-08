import AppKit
import SwiftUI

final class PreferencesWindowController {
    private var window: NSWindow?
    private let configManager: ConfigManager

    init(configManager: ConfigManager) {
        self.configManager = configManager
    }

    func showPreferences() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let prefsView = PreferencesView(configManager: configManager)
        let hostingController = NSHostingController(rootView: prefsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "SpaceWidget Preferences"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
