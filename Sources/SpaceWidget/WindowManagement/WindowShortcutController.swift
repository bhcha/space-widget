import Foundation

final class WindowShortcutController {
    private let hotKeyManager = HotKeyManager()
    private let snapManager = WindowSnapManager()
    private let configManager: ConfigManager
    private let templateStore: LayoutTemplateStore?
    private let applier: LayoutApplier?

    init(configManager: ConfigManager,
         templateStore: LayoutTemplateStore? = nil,
         applier: LayoutApplier? = nil) {
        self.configManager = configManager
        self.templateStore = templateStore
        self.applier = applier
    }

    func registerShortcuts() {
        hotKeyManager.unregisterAll()

        for action in WindowAction.allCases {
            guard let binding = configManager.shortcuts[action.rawValue],
                  binding.enabled else { continue }

            hotKeyManager.register(keyCode: binding.keyCode, modifiers: binding.modifiers) { [weak self] in
                self?.snapManager.execute(action)
            }
        }

        // Register template shortcuts
        guard let store = templateStore, let applier = applier else { return }
        for template in store.templates {
            guard let binding = template.shortcut, binding.enabled else { continue }
            let templateCopy = template
            hotKeyManager.register(keyCode: binding.keyCode, modifiers: binding.modifiers) { [weak store] in
                applier.apply(templateCopy, launchClosedApps: store?.launchClosedApps ?? false)
            }
        }
    }
}
