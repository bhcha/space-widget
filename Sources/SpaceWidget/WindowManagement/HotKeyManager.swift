import AppKit
import Carbon

final class HotKeyManager {
    private var hotKeys: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var nextId: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    init() {
        installEventHandler()
    }

    deinit {
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> UInt32 {
        let id = nextId
        nextId += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x5357_4B59), id: id) // "SWKY"
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        if status == noErr {
            hotKeys[id] = handler
            hotKeyRefs[id] = hotKeyRef
        } else {
            swLog("HOTKEY", "Failed to register keyCode=\(keyCode) modifiers=\(modifiers) error=\(status)")
        }

        return id
    }

    func unregisterAll() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeys.removeAll()
        hotKeyRefs.removeAll()
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()

            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                            nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)

            if let action = manager.hotKeys[hotKeyID.id] {
                DispatchQueue.main.async { action() }
            }
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), handler, 1, &eventType, selfPtr, &eventHandler)
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
