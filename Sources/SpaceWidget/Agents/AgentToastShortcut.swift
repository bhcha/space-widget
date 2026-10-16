import Foundation
import Combine

protocol AgentShortcutRegistering: AnyObject {
    func registerOverride(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> UInt32
    func isRegistered(_ id: UInt32) -> Bool
    func unregisterAll()
}
extension HotKeyManager: AgentShortcutRegistering {}

/// Reserves the global shortcut only while an actionable toast is visible.
/// Temporarily takes priority over a matching SpaceWidget window shortcut.
@MainActor
final class AgentToastShortcut: ObservableObject {
    static let shared = AgentToastShortcut()
    static let defaultBinding = ShortcutBinding(keyCode: 0x05, modifiers: 0x1800, enabled: true) // ⌃⌥G (Go)
    @Published var binding: ShortcutBinding {
        didSet {
            defaults.set(try? JSONEncoder().encode(binding), forKey: "agentToastShortcut")
            reconcile()
        }
    }
    @Published private(set) var issue: String?
    @Published private(set) var registered = false
    private let defaults: UserDefaults
    private let registrar: AgentShortcutRegistering
    private var available = false
    private var recording = false
    private var action: (() -> Void)?
    private var generation = UUID()

    init(defaults: UserDefaults = .standard, registrar: AgentShortcutRegistering = HotKeyManager()) {
        self.defaults = defaults
        self.registrar = registrar
        binding = defaults.data(forKey: "agentToastShortcut").flatMap {
            try? JSONDecoder().decode(ShortcutBinding.self, from: $0)
        } ?? Self.defaultBinding
    }

    func configure(available: Bool, action: (() -> Void)? = nil) {
        self.available = available
        self.action = action
        reconcile()
    }

    func setRecording(_ value: Bool) { recording = value; reconcile() }

    private func reconcile() {
        registrar.unregisterAll()
        registered = false
        issue = nil
        generation = UUID()
        guard available, !recording, binding.enabled else { return }
        guard binding.modifiers & 0x1B00 != 0, binding.keyCode <= 127 else {
            issue = "Include at least one modifier: ⌘, ⌥, ⌃, or ⇧."
            return
        }
        let generation = generation
        let id = registrar.registerOverride(keyCode: binding.keyCode, modifiers: binding.modifiers) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.registered else { return }
                self.action?()
            }
        }
        registered = registrar.isRegistered(id)
        if !registered { issue = "This shortcut is already in use. Choose another combination." }
    }
}
