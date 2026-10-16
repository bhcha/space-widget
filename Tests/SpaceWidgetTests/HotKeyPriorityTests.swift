import XCTest
import AppKit
import Carbon
@testable import SpaceWidget

final class HotKeyPriorityTests: XCTestCase {
    /// Dispatches only an app-local Carbon event to fixture callbacks, not a user keypress.
    @MainActor
    private func press(_ nativeID: UInt32) async throws {
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                   GetCurrentEventTime(), 0, &event), noErr)
        let eventRef = try XCTUnwrap(event)
        defer { ReleaseEvent(eventRef) }
        var id = EventHotKeyID(signature: OSType(0x5357_4B59), id: nativeID)
        XCTAssertEqual(SetEventParameter(eventRef, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id), noErr)
        XCTAssertEqual(SendEventToEventTarget(eventRef, GetEventDispatcherTarget()), noErr)
        // The production dispatcher deliberately queues delivery on the main thread.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    func testToastTemporarilyOverridesWindowShortcutAndRestoresItAfterDismissal() async throws {
        _ = NSApplication.shared
        let windows = HotKeyManager(), toast = HotKeyManager()
        defer { toast.unregisterAll(); windows.unregisterAll() }
        var windowCalls = 0, toastCalls = 0
        let key: UInt32 = 0x5A, modifiers: UInt32 = 0x1B00 // F20, isolated from normal app shortcuts
        let native = windows.register(keyCode: key, modifiers: modifiers) { windowCalls += 1 }
        XCTAssertTrue(windows.isRegistered(native))
        try await press(native)
        XCTAssertEqual(windowCalls, 1)
        let overlay = toast.registerOverride(keyCode: key, modifiers: modifiers) { toastCalls += 1 }
        XCTAssertTrue(toast.isRegistered(overlay))
        try await press(native)
        XCTAssertEqual(toastCalls, 1)
        XCTAssertEqual(windowCalls, 1, "A Go press must not also resize the window")
        toast.unregisterAll()
        try await press(native)
        XCTAssertEqual(windowCalls, 2)
        XCTAssertEqual(toastCalls, 1)
    }

    @MainActor
    func testWindowShortcutReloadDuringToastRestoresLatestActionAndRejectsNormalDuplicates() async throws {
        _ = NSApplication.shared
        let windows = HotKeyManager(), duplicate = HotKeyManager(), toast = HotKeyManager()
        defer { toast.unregisterAll(); duplicate.unregisterAll(); windows.unregisterAll() }
        let key: UInt32 = 0x50, modifiers: UInt32 = 0x1B00 // F19
        var oldCalls = 0, newCalls = 0, toastCalls = 0
        let native = windows.register(keyCode: key, modifiers: modifiers) { oldCalls += 1 }
        let rejected = duplicate.register(keyCode: key, modifiers: modifiers) { XCTFail("Duplicate shortcut ran") }
        XCTAssertFalse(duplicate.isRegistered(rejected))
        let overlay = toast.registerOverride(keyCode: key, modifiers: modifiers) { toastCalls += 1 }
        XCTAssertTrue(toast.isRegistered(overlay))
        windows.unregisterAll()
        let replacement = windows.register(keyCode: key, modifiers: modifiers) { newCalls += 1 }
        XCTAssertTrue(windows.isRegistered(replacement))
        try await press(native)
        XCTAssertEqual(toastCalls, 1)
        XCTAssertEqual(oldCalls + newCalls, 0)
        toast.unregisterAll()
        try await press(native)
        XCTAssertEqual(newCalls, 1)
        XCTAssertEqual(oldCalls, 0)
    }

    @MainActor
    func testOverrideCanRegisterFirstAndItsOwnerDeallocationRestoresWindowAction() async throws {
        _ = NSApplication.shared
        var toast: HotKeyManager? = HotKeyManager()
        let windows = HotKeyManager()
        defer { toast?.unregisterAll(); windows.unregisterAll() }
        let key: UInt32 = 0x4F, modifiers: UInt32 = 0x1B00 // F18
        var windowCalls = 0, toastCalls = 0
        let native = toast!.registerOverride(keyCode: key, modifiers: modifiers) { toastCalls += 1 }
        XCTAssertTrue(toast!.isRegistered(native))
        let normal = windows.register(keyCode: key, modifiers: modifiers) { windowCalls += 1 }
        XCTAssertTrue(windows.isRegistered(normal))
        try await press(native)
        XCTAssertEqual(toastCalls, 1)
        XCTAssertEqual(windowCalls, 0)
        toast = nil
        try await press(native)
        XCTAssertEqual(windowCalls, 1)
    }
}
