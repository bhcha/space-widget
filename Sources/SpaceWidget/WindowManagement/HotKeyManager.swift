import AppKit
import Carbon

/// Registrations are managed on the main thread. A visible toast may temporarily
/// override this app's window shortcut without registering a conflicting OS key.
final class HotKeyManager {
    private struct Key: Hashable {
        let code: UInt32
        let modifiers: UInt32
    }
    private struct Action {
        let id: UInt32
        let handler: () -> Void
    }
    private final class Slot {
        let nativeID: UInt32
        let reference: EventHotKeyRef
        var normal: Action?
        var transient: Action?
        var active: Action? { transient ?? normal }
        init(nativeID: UInt32, reference: EventHotKeyRef) {
            self.nativeID = nativeID
            self.reference = reference
        }
    }

    private static var slots: [Key: Slot] = [:]
    private static var nextId: UInt32 = 1
    private var registrations: [UInt32: Key] = [:]
    private var eventHandler: EventHandlerRef?

    init() { installEventHandler() }

    deinit {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> UInt32 {
        register(keyCode: keyCode, modifiers: modifiers, overriding: false, handler: handler)
    }

    @discardableResult
    func registerOverride(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> UInt32 {
        register(keyCode: keyCode, modifiers: modifiers, overriding: true, handler: handler)
    }

    private func register(keyCode: UInt32, modifiers: UInt32, overriding: Bool, handler: @escaping () -> Void) -> UInt32 {
        let id = Self.nextId
        Self.nextId += 1
        let key = Key(code: keyCode, modifiers: modifiers)
        let slot: Slot
        if let existing = Self.slots[key] {
            // Ordinary duplicates still fail. Only a transient override can share a key.
            guard overriding ? existing.transient == nil : existing.normal == nil else { return id }
            slot = existing
        } else {
            let hotKeyID = EventHotKeyID(signature: OSType(0x5357_4B59), id: id) // "SWKY"
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &reference)
            guard status == noErr, let reference else {
                swLog("HOTKEY", "Failed to register keyCode=\(keyCode) modifiers=\(modifiers) error=\(status)")
                return id
            }
            slot = Slot(nativeID: id, reference: reference)
            Self.slots[key] = slot
        }
        let action = Action(id: id, handler: handler)
        if overriding { slot.transient = action } else { slot.normal = action }
        registrations[id] = key
        return id
    }

    func isRegistered(_ id: UInt32) -> Bool { registrations[id] != nil }

    func unregisterAll() {
        for (id, key) in registrations {
            guard let slot = Self.slots[key] else { continue }
            if slot.normal?.id == id { slot.normal = nil }
            if slot.transient?.id == id { slot.transient = nil }
            if slot.active == nil {
                UnregisterEventHotKey(slot.reference)
                Self.slots.removeValue(forKey: key)
            }
        }
        registrations.removeAll()
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID) == noErr,
                  hotKeyID.signature == OSType(0x5357_4B59),
                  let slot = HotKeyManager.slots.values.first(where: { $0.nativeID == hotKeyID.id }),
                  let action = slot.active else { return OSStatus(eventNotHandledErr) }
            let nativeID = hotKeyID.id
            DispatchQueue.main.async {
                // A queued press must not run a stale action after a toast/config change.
                guard HotKeyManager.slots.values.first(where: { $0.nativeID == nativeID })?.active?.id == action.id else { return }
                action.handler()
            }
            return noErr
        }
        InstallEventHandler(GetEventDispatcherTarget(), handler, 1, &eventType, nil, &eventHandler)
    }
}

// MARK: - Key code and modifier helpers

extension HotKeyManager {
    /// Carbon modifier flags (from Carbon/HIToolbox)
    /// controlKey = 0x1000, optionKey = 0x0800, cmdKey = 0x0100, shiftKey = 0x0200
    static let carbonCmdKey: UInt32     = 0x0100
    static let carbonOptionKey: UInt32  = 0x0800
    static let carbonControlKey: UInt32 = 0x1000
    static let carbonShiftKey: UInt32   = 0x0200

    /// Common virtual key codes (same as AppKit / Carbon kVK_*)
    static let kVK_Return: UInt32      = 0x24
    static let kVK_LeftArrow: UInt32   = 0x7B
    static let kVK_RightArrow: UInt32  = 0x7C
    static let kVK_ANSI_D: UInt32      = 0x02
    static let kVK_ANSI_E: UInt32      = 0x0E
    static let kVK_ANSI_F: UInt32      = 0x03
    static let kVK_ANSI_G: UInt32      = 0x05
    static let kVK_ANSI_C: UInt32      = 0x08
    static let kVK_ANSI_T: UInt32      = 0x11
}
