import AppKit
import SwiftUI

final class PreferencesWindowController {
    private var window: NSWindow?
    private let configManager: ConfigManager
    private let templateStore: LayoutTemplateStore

    init(configManager: ConfigManager, templateStore: LayoutTemplateStore) {
        self.configManager = configManager
        self.templateStore = templateStore
    }

    func showPreferences() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let prefsView = PreferencesView(configManager: configManager, templateStore: templateStore)
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
