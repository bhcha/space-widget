import AppKit

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem

    override init() {
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

        let quitItem = NSMenuItem(
            title: "Quit SpaceWidget",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

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
