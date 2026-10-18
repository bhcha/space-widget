import XCTest
import AppKit
@testable import SpaceWidget

@MainActor
final class OriginBackendFixture: AgentOriginBackend {
    var state = AgentOriginSnapshot(permitted: true, spaces: [])
    var switched: [UInt64] = []
    var current: UInt64?
    var switchAllowed = true
    var queriedDisplays: [String] = []
    var afterSwitch: (() -> Void)?
    func snapshot() -> AgentOriginSnapshot { state }
    func requestSwitch(to space: AgentOriginSnapshot.Space) {
        switched.append(space.id)
        if switchAllowed { current = space.id }
        afterSwitch?()
    }
    func currentSpace(on displayID: String) -> UInt64? { queriedDisplays.append(displayID); return current }
}

final class AgentOriginNavigationTests: XCTestCase {
    private let target = AgentOrigin(displayID: "display", spaceUUID: "project-space")
    private func space(id: UInt64 = 7, ordinal: Int = 2, uuid: String = "project-space", display: String = "display") -> AgentOriginSnapshot.Space {
        .init(uuid: uuid, id: id, ordinal: ordinal, displayID: display)
    }

    func testCaptureRequiresEveryHostWindowToShareOneSpace() {
        let other = AgentOrigin(displayID: "other", spaceUUID: "other-space")
        XCTAssertEqual(AgentSpaceCapture.select(windowSpaces: [[target]]), target)
        XCTAssertEqual(AgentSpaceCapture.select(windowSpaces: [[target], [target]]), target)
        // The host being foreground cannot distinguish a request in target from
        // one in other. Foreground state is deliberately no longer a selection input.
        XCTAssertNil(AgentSpaceCapture.select(windowSpaces: [[target], [other]]))
        XCTAssertNil(AgentSpaceCapture.select(windowSpaces: [[other], [target]]))
        XCTAssertNil(AgentSpaceCapture.select(windowSpaces: [[target, other]]))
        XCTAssertNil(AgentSpaceCapture.select(windowSpaces: [[target], [target, other]]))
        XCTAssertNil(AgentSpaceCapture.select(windowSpaces: [[], [target]]))
        XCTAssertNil(AgentSpaceCapture.select(windowSpaces: []))
    }

    @MainActor
    func testNavigatesToCapturedSpaceWithoutWindowBindingAndSurvivesReordering() async {
        let backend = OriginBackendFixture()
        backend.state = .init(permitted: true, spaces: [space(ordinal: 4)])
        let navigation = AgentOriginNavigation(backend: backend, log: { _ in })
        let event = AgentHookEvent(agentID: "codex", source: "source", session: "hidden-session", kind: "Stop", turn: "t", received: Date(), project: "space-widget", origin: target, originCapturePolicy: AgentSpaceCapture.policy)
        XCTAssertEqual(navigation.origin(for: event), target)
        XCTAssertEqual(navigation.label(for: target), "Space 4")
        let moved = await navigation.navigate(to: target)
        XCTAssertTrue(moved)
        XCTAssertEqual(backend.switched, [7])
        // Already on that Space: neither permission nor any window is needed.
        backend.state = .init(permitted: false, spaces: [space()])
        let same = await navigation.navigate(to: target)
        XCTAssertTrue(same)
        XCTAssertEqual(backend.switched, [7])
    }

    @MainActor
    func testMissingSpaceDisconnectedDisplayDuplicateUUIDAndPermissionNeverSwitchElsewhere() async {
        let backend = OriginBackendFixture()
        let navigation = AgentOriginNavigation(backend: backend, log: { _ in })
        for state in [AgentOriginSnapshot(permitted: false, spaces: [space()]),
                      .init(permitted: true, spaces: []),
                      .init(permitted: true, spaces: [space(uuid: "replacement")]),
                      .init(permitted: true, spaces: [space(uuid: "other-desktop", display: "new-display")]),
                      .init(permitted: true, spaces: [space(), space(id: 8, display: "new-display")]),
                      .init(permitted: true, spaces: [space(), space(id: 8)])] {
            backend.state = state
            let result = await navigation.navigate(to: target)
            XCTAssertFalse(result)
        }
        XCTAssertTrue(backend.switched.isEmpty)
    }

    @MainActor
    func testSameDesktopAfterDisplayMigrationUsesLiveDisplayForNoticeAndArrival() async {
        let backend = OriginBackendFixture()
        backend.state = .init(permitted: true, spaces: [space(id: 24, ordinal: 3, display: "new-display")])
        let navigation = AgentOriginNavigation(backend: backend, log: { _ in }, wait: { _ in })
        let event = AgentHookEvent(agentID: "codex", source: "fixture", session: "session", kind: "Stop",
            turn: "turn", received: Date(), project: "text2sql", origin: target, originCapturePolicy: AgentSpaceCapture.policy)
        XCTAssertEqual(navigation.origin(for: event), .init(displayID: "new-display", spaceUUID: target.spaceUUID))
        XCTAssertEqual(navigation.label(for: target), "Space 3")
        let moved = await navigation.navigate(to: target)
        XCTAssertTrue(moved)
        XCTAssertEqual(backend.switched, [24])
        XCTAssertEqual(Set(backend.queriedDisplays), ["new-display"])
    }

    @MainActor
    func testMigrationDuringNavigationCannotConfirmArrivalOnTheOldDisplay() async {
        let backend = OriginBackendFixture()
        backend.state = .init(permitted: true, spaces: [space()])
        backend.afterSwitch = { backend.state = .init(permitted: true, spaces: [self.space(display: "new-display")]) }
        let navigation = AgentOriginNavigation(backend: backend, log: { _ in }, wait: { _ in })
        let moved = await navigation.navigate(to: target)
        XCTAssertFalse(moved)
    }

    @MainActor
    func testOptInReadOnlyLiveDisplayMigrationResolution() throws {
        let env = ProcessInfo.processInfo.environment
        guard let uuid = env["SPACEWIDGET_QA_TARGET_UUID"],
              let oldDisplay = env["SPACEWIDGET_QA_CAPTURED_DISPLAY"],
              let path = env["SPACEWIDGET_QA_TRACE_PATH"] else {
            throw XCTSkip("Explicit captured origin and evidence path required")
        }
        let backend = NativeAgentOriginBackend()
        let navigation = AgentOriginNavigation(backend: backend, log: { _ in },
            diagnostics: .file(at: URL(fileURLWithPath: path)))
        let event = AgentHookEvent(agentID: "codex", source: "read-only-display-qa", session: "fixture",
            kind: "Stop", turn: "fixture", received: Date(), project: "text2sql-display-migration-QA",
            origin: .init(displayID: oldDisplay, spaceUUID: uuid), originCapturePolicy: AgentSpaceCapture.policy)
        let resolved = try XCTUnwrap(navigation.origin(for: event))
        XCTAssertEqual(resolved.spaceUUID, uuid)
        XCTAssertNotEqual(resolved.displayID, oldDisplay)
        XCTAssertNotNil(navigation.label(for: resolved))
    }

    @MainActor
    func testRevalidatesSpaceAfterSwitchAndReportsFailure() async {
        let backend = OriginBackendFixture()
        backend.state = .init(permitted: true, spaces: [space()])
        let navigation = AgentOriginNavigation(backend: backend, log: { _ in })
        backend.afterSwitch = { backend.state = .init(permitted: true, spaces: [self.space(uuid: "removed")]) }
        let stale = await navigation.navigate(to: target)
        XCTAssertFalse(stale)
        backend.state = .init(permitted: true, spaces: [space()])
        backend.current = nil
        backend.switchAllowed = false
        backend.afterSwitch = nil
        let denied = await navigation.navigate(to: target)
        XCTAssertFalse(denied)
    }

    @MainActor
    func testProjectFirstNoticeRetainsCapturedSpaceAndNeverDisplaysSessionID() throws {
        let backend = OriginBackendFixture()
        backend.state = .init(permitted: true, spaces: [space()])
        let navigation = AgentOriginNavigation(backend: backend, log: { _ in })
        let event = AgentHookEvent(agentID: "codex", source: "source", session: "sensitive-session-id", kind: "Stop", turn: "t", received: Date(), project: "space-widget", origin: target, originCapturePolicy: AgentSpaceCapture.policy)
        let suite = "AgentSpaceNotice." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var notices: [AgentCompletionNotice] = []
        let model = AgentNotificationModel(defaults: defaults, originNavigation: navigation, present: { notices.append($0) })
        model.receive(event)
        let notice = try XCTUnwrap(notices.first)
        XCTAssertEqual(notice.title, "space-widget")
        XCTAssertEqual(notice.status, "done")
        XCTAssertEqual(notice.detail, "Codex · Space 2")
        XCTAssertFalse((notice.title + notice.detail).contains(event.session))
        XCTAssertEqual(notice.origin, target)
    }
}

extension AgentOriginNavigationTests {
    @MainActor
    func testLegacyCaptureAndUnavailableSpaceHaveDistinctNonNavigableNotices() throws {
        let backend = OriginBackendFixture()
        backend.state = .init(permitted: true, spaces: [space()])
        let navigation = AgentOriginNavigation(backend: backend, log: { _ in })
        let suite = "OriginSafety." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var notices: [AgentCompletionNotice] = []
        let model = AgentNotificationModel(defaults: defaults, originNavigation: navigation,
            present: { notices.append($0) })
        var event = AgentHookEvent(agentID: "claude", source: "fixture", session: "s", kind: "Stop",
            turn: "t", received: Date(), project: "governance", origin: target)
        for policy in [nil, "unknown_future_policy"] as [String?] {
            event.originCapturePolicy = policy
            model.receive(event)
            XCTAssertNil(notices.last?.destination)
            XCTAssertTrue(notices.last?.navigationIssue?.contains("could not be verified") == true)
        }
        event.origin = nil
        model.receive(event)
        XCTAssertEqual(notices.last?.navigationIssue, "Could not determine the Space where this task started.")
        event.origin = target
        event.originCapturePolicy = AgentSpaceCapture.policy
        backend.state = .init(permitted: true, spaces: [])
        model.receive(event)
        XCTAssertEqual(notices.last?.navigationIssue, "The Space where this task started is no longer available.")
        XCTAssertNil(notices.last?.destination)
        XCTAssertTrue(backend.switched.isEmpty)
        backend.state = .init(permitted: true, spaces: [space()])
        model.receive(event)
        XCTAssertEqual(notices.last?.destination, target)
        XCTAssertNil(notices.last?.navigationIssue)
    }

    @MainActor
    func testWrongSpaceAndBriefArrivalCannotCountAsSuccess() async {
        let backend = OriginBackendFixture()
        backend.state = .init(permitted: true, spaces: [space()])
        backend.afterSwitch = { backend.current = 99 }
        let navigation = AgentOriginNavigation(backend: backend, log: { _ in }, wait: { _ in })
        let wrong = await navigation.navigate(to: target)
        XCTAssertFalse(wrong)
        XCTAssertEqual(backend.switched, [7])
        backend.current = nil
        backend.afterSwitch = nil
        var samples = 0
        let bouncing = AgentOriginNavigation(backend: backend, log: { _ in }, wait: { _ in
            samples += 1
            if samples == 2 { backend.current = 99 }
        })
        let bounced = await bouncing.navigate(to: target)
        XCTAssertFalse(bounced, "A momentary arrival followed by a bounce is not success")
    }
}
