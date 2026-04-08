import Foundation

final class WindowShortcutController {
    private let hotKeyManager = HotKeyManager()
    private let snapManager = WindowSnapManager()
    private let configManager: ConfigManager

    init(configManager: ConfigManager) {
        self.configManager = configManager
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
    }
}
