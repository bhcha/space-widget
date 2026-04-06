import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let autoHideManager: AutoHideManager
    private var autoHideItem: NSMenuItem?

    init(autoHideManager: AutoHideManager) {
        self.autoHideManager = autoHideManager
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureStatusItem()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = loadMenuBarIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "SpaceWidget"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let autoHideItem = NSMenuItem(
            title: "Auto Hide",
            action: #selector(toggleAutoHide),
            keyEquivalent: ""
        )
        autoHideItem.target = self
        autoHideItem.state = autoHideManager.isEnabled ? .on : .off
        menu.addItem(autoHideItem)
        self.autoHideItem = autoHideItem

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit SpaceWidget",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        autoHideItem?.state = autoHideManager.isEnabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func toggleAutoHide() {
        autoHideManager.toggle()
    }

    // MARK: - Icon

    private func loadMenuBarIcon() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "icon", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else {
            return NSImage(
                systemSymbolName: "rectangle.3.group.bubble",
                accessibilityDescription: "SpaceWidget"
            )
        }

        image.isTemplate = false
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}
