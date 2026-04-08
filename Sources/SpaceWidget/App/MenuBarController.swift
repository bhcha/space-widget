import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let autoHideManager: AutoHideManager
    private let configManager: ConfigManager
    private let dockController: DockController
    private let preferencesController: PreferencesWindowController
    private let templateStore: LayoutTemplateStore?
    private let applier: LayoutApplier?
    private var autoHideItem: NSMenuItem?
    private var iconsPerPageItems: [NSMenuItem] = []
    private var dockModeItems: [NSMenuItem] = []
    private var layoutsSubmenu: NSMenu?
    private var autoApplyItem: NSMenuItem?

    init(autoHideManager: AutoHideManager, configManager: ConfigManager, dockController: DockController, preferencesController: PreferencesWindowController, templateStore: LayoutTemplateStore? = nil, applier: LayoutApplier? = nil) {
        self.autoHideManager = autoHideManager
        self.configManager = configManager
        self.dockController = dockController
        self.preferencesController = preferencesController
        self.templateStore = templateStore
        self.applier = applier
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

        let iconsPerPageMenu = NSMenu()
        var ippItems: [NSMenuItem] = []
        for count in ConfigManager.iconsPerPageRange {
            let item = NSMenuItem(
                title: "\(count)",
                action: #selector(changeIconsPerPage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = count
            item.state = (count == configManager.iconsPerPage) ? .on : .off
            iconsPerPageMenu.addItem(item)
            ippItems.append(item)
        }
        self.iconsPerPageItems = ippItems

        let iconsPerPageItem = NSMenuItem(title: "Icons per Page", action: nil, keyEquivalent: "")
        iconsPerPageItem.submenu = iconsPerPageMenu
        menu.addItem(iconsPerPageItem)

        let dockMenu = NSMenu()
        let dockModeLabels = ["Auto Hide", "Always Hide", "Always Show"]
        let currentDockMode = dockController.currentMode
        var dockItems: [NSMenuItem] = []
        for (tag, label) in dockModeLabels.enumerated() {
            let item = NSMenuItem(
                title: label,
                action: #selector(changeDockMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = tag
            let modeForTag: DockMode = [.autoHide, .alwaysHide, .alwaysShow][tag]
            item.state = (modeForTag == currentDockMode) ? .on : .off
            dockMenu.addItem(item)
            dockItems.append(item)
        }
        self.dockModeItems = dockItems

        let dockItem = NSMenuItem(title: "Dock", action: nil, keyEquivalent: "")
        dockItem.submenu = dockMenu
        menu.addItem(dockItem)

        // Layouts submenu
        if let store = templateStore {
            let layoutsMenu = NSMenu()
            for template in store.templates {
                let item = NSMenuItem(
                    title: template.name,
                    action: #selector(applyLayout(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = template.id.uuidString
                layoutsMenu.addItem(item)
            }
            layoutsMenu.addItem(NSMenuItem.separator())
            let autoApplyItem = NSMenuItem(
                title: "Auto-apply on Space Switch",
                action: #selector(toggleAutoApply),
                keyEquivalent: ""
            )
            autoApplyItem.target = self
            autoApplyItem.state = store.autoApplyEnabled ? .on : .off
            layoutsMenu.addItem(autoApplyItem)
            self.autoApplyItem = autoApplyItem
            self.layoutsSubmenu = layoutsMenu

            let layoutsItem = NSMenuItem(title: "Layouts", action: nil, keyEquivalent: "")
            layoutsItem.submenu = layoutsMenu
            menu.addItem(layoutsItem)
        }

        menu.addItem(NSMenuItem.separator())

        let prefsItem = NSMenuItem(
            title: "Preferences...",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        prefsItem.target = self
        menu.addItem(prefsItem)

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
        let current = configManager.iconsPerPage
        for item in iconsPerPageItems {
            item.state = (item.tag == current) ? .on : .off
        }
        let currentDockMode = dockController.currentMode
        let modes: [DockMode] = [.autoHide, .alwaysHide, .alwaysShow]
        for item in dockModeItems {
            guard item.tag >= 0, item.tag < modes.count else { continue }
            item.state = (modes[item.tag] == currentDockMode) ? .on : .off
        }
        // Update layouts submenu
        if let store = templateStore, let layoutsMenu = layoutsSubmenu {
            // Remove template items (keep separator + auto-apply at end)
            while layoutsMenu.items.count > 2 {
                layoutsMenu.removeItem(at: 0)
            }
            // Re-insert template items
            for (index, template) in store.templates.enumerated() {
                let item = NSMenuItem(
                    title: template.name,
                    action: #selector(applyLayout(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = template.id.uuidString
                layoutsMenu.insertItem(item, at: index)
            }
            autoApplyItem?.state = store.autoApplyEnabled ? .on : .off
        }
    }

    // MARK: - Actions

    @objc private func toggleAutoHide() {
        autoHideManager.toggle()
    }

    @objc private func changeIconsPerPage(_ sender: NSMenuItem) {
        configManager.saveIconsPerPage(sender.tag)
    }

    @objc private func changeDockMode(_ sender: NSMenuItem) {
        let modes: [DockMode] = [.autoHide, .alwaysHide, .alwaysShow]
        guard sender.tag >= 0, sender.tag < modes.count else { return }
        dockController.apply(mode: modes[sender.tag])
    }

    @objc private func applyLayout(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let uuid = UUID(uuidString: idString),
              let template = templateStore?.templates.first(where: { $0.id == uuid })
        else { return }
        applier?.apply(template, launchClosedApps: templateStore?.launchClosedApps ?? false)
    }

    @objc private func toggleAutoApply() {
        guard let store = templateStore else { return }
        store.setAutoApplyEnabled(!store.autoApplyEnabled)
    }

    @objc private func openPreferences() {
        preferencesController.showPreferences()
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

        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}
