import XCTest
import AppKit
@testable import SpaceWidget

final class ShortcutRegistrarFixture: AgentShortcutRegistering {
    var succeeds = true
    var handlers: [() -> Void] = []
    var current: UInt32?
    var keys: [ShortcutBinding] = []
    func registerOverride(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> UInt32 {
        keys.append(.init(keyCode: keyCode, modifiers: modifiers, enabled: true))
        handlers.append(handler)
        let id = UInt32(handlers.count)
        if succeeds { current = id }
        return id
    }
    func isRegistered(_ id: UInt32) -> Bool { current == id }
    func unregisterAll() { current = nil }
    func fire() { if let current { handlers[Int(current) - 1]() } }
}

final class AgentToastShortcutTests: XCTestCase {
    @MainActor
    func testBindingPersistsSuspendsDuringRecordingAndDoesNotReserveWhenHidden() throws {
        let suite = "AgentShortcut." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registrar = ShortcutRegistrarFixture()
        let shortcut = AgentToastShortcut(defaults: defaults, registrar: registrar)
        XCTAssertNil(registrar.current)
        XCTAssertEqual(shortcut.binding.keyCode, 0x05)
        XCTAssertEqual(shortcut.binding.modifiers, 0x1800)
        XCTAssertEqual(shortcut.binding.displayString, "⌥⌃G")
        var activations = 0
        shortcut.configure(available: true) { activations += 1 }
        XCTAssertTrue(shortcut.registered)
        registrar.fire()
        XCTAssertEqual(activations, 1)
        let stale = registrar.handlers[0]
        shortcut.binding = .init(keyCode: 0x0B, modifiers: 0x1100, enabled: true)
        stale()
        XCTAssertEqual(activations, 1, "Queued callbacks of a replaced shortcut must be ignored")
        XCTAssertEqual(registrar.keys.last, shortcut.binding)
        shortcut.setRecording(true)
        XCTAssertNil(registrar.current)
        shortcut.setRecording(false)
        XCTAssertTrue(shortcut.registered)
        shortcut.configure(available: false)
        XCTAssertNil(registrar.current)
        XCTAssertEqual(AgentToastShortcut(defaults: defaults, registrar: ShortcutRegistrarFixture()).binding, shortcut.binding)
        shortcut.binding.enabled = false
        shortcut.configure(available: true) { activations += 1 }
        XCTAssertNil(registrar.current)
    }

    @MainActor
    func testConflictIsReportedAndNeverClaimsActiveShortcut() {
        let registrar = ShortcutRegistrarFixture()
        registrar.succeeds = false
        let shortcut = AgentToastShortcut(registrar: registrar)
        shortcut.configure(available: true) { XCTFail("Conflicting shortcut fired") }
        XCTAssertFalse(shortcut.registered)
        XCTAssertNotNil(shortcut.issue)
        shortcut.configure(available: false)
        XCTAssertNil(shortcut.issue)
    }

    @MainActor
    func testShortcutAndClickNavigateOnlyVisibleToastAndReleaseAfterDismiss() async throws {
        _ = NSApplication.shared
        let backend = OriginBackendFixture()
        let a = AgentOriginSnapshot.Space(uuid: "a", id: 1, ordinal: 1, displayID: "display")
        let b = AgentOriginSnapshot.Space(uuid: "b", id: 2, ordinal: 2, displayID: "display")
        backend.state = .init(permitted: true, spaces: [a, b])
        let registrar = ShortcutRegistrarFixture()
        let shortcut = AgentToastShortcut(registrar: registrar)
        let presenter = AgentToastPresenter(navigation: AgentOriginNavigation(backend: backend, log: { _ in }), shortcut: shortcut)
        defer { presenter.clear() }
        func notice(_ space: AgentOriginSnapshot.Space) -> AgentCompletionNotice {
            .init(event: .init(agentID: "codex", source: "fixture", session: space.uuid, kind: "Stop", turn: nil, received: Date(), project: "space-widget", application: .init(bundleID: "com.mitchellh.ghostty", processID: 42, name: "Ghostty")), space: "Space \(space.ordinal)", isTest: false, origin: space.origin)
        }
        let first = notice(a), second = notice(b)
        presenter.show(first)
        presenter.show(second)
        XCTAssertTrue(shortcut.registered)
        if let destination = ProcessInfo.processInfo.environment["SPACEWIDGET_ACTIONABLE_TOAST_PNG"] {
            let view = try XCTUnwrap(presenter.panel?.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: destination))
        }
        let stale = registrar.handlers.last!
        registrar.fire()
        for _ in 0..<200 {
            if presenter.currentNotice?.id == second.id { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(backend.switched, [1])
        XCTAssertEqual(presenter.currentNotice?.id, second.id)
        stale()
        await presenter.activate(first) // stale click
        XCTAssertEqual(backend.switched, [1])
        backend.current = nil
        await presenter.activate(second)
        XCTAssertEqual(backend.switched, [1, 2])
        XCTAssertNil(presenter.currentNotice)
        XCTAssertFalse(shortcut.registered)
        registrar.fire()
        await presenter.activateCurrent()
        XCTAssertEqual(backend.switched, [1, 2])
        presenter.show(.init(event: first.event, space: nil, isTest: true))
        XCTAssertFalse(shortcut.registered)
    }

    @MainActor
    func testDifferentHotKeyManagersCannotCollideInHandlerIDs() {
        let first = HotKeyManager(), second = HotKeyManager()
        defer { first.unregisterAll(); second.unregisterAll() }
        let a = first.register(keyCode: 0x7A, modifiers: 0x1B00) {}
        let b = second.register(keyCode: 0x78, modifiers: 0x1B00) {}
        XCTAssertNotEqual(a, b)
    }
}

extension AgentToastShortcutTests {
    @MainActor
    func testShortcutKeepsPriorityWhileSpaceNavigationIsInFlight() async throws {
        _ = NSApplication.shared
        let backend = OriginBackendFixture()
        let space = AgentOriginSnapshot.Space(uuid: "target", id: 10, ordinal: 2, displayID: "display")
        backend.state = .init(permitted: true, spaces: [space])
        backend.afterSwitch = { backend.current = nil }
        let registrar = ShortcutRegistrarFixture()
        let shortcut = AgentToastShortcut(registrar: registrar)
        let presenter = AgentToastPresenter(navigation: AgentOriginNavigation(backend: backend, log: { _ in }), shortcut: shortcut)
        defer { presenter.clear() }
        let notice = AgentCompletionNotice(event: .init(agentID: "codex", source: "fixture", session: "s", kind: "Stop", turn: nil, received: Date()), space: "Space 2", isTest: false, origin: space.origin)
        presenter.show(notice)
        let navigation = Task { await presenter.activate(notice) }
        for _ in 0..<200 {
            if !backend.switched.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(shortcut.registered, "Go must not fall through to window resizing during animation")
        XCTAssertEqual(presenter.currentNotice?.id, notice.id)
        registrar.fire()
        backend.current = space.id
        await navigation.value
        XCTAssertEqual(backend.switched, [10])
        XCTAssertNil(presenter.currentNotice)
        XCTAssertFalse(shortcut.registered)
    }
}
