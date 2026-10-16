import XCTest
import AppKit
@testable import SpaceWidget

@MainActor
final class OriginBackendFixture: AgentOriginBackend {
    var state = AgentOriginSnapshot(permitted: true, spaces: [])
    var switched: [UInt64] = []
    var current: UInt64?
    var switchAllowed = true
    var afterSwitch: (() -> Void)?
    func snapshot() -> AgentOriginSnapshot { state }
    func requestSwitch(to space: AgentOriginSnapshot.Space) {
        switched.append(space.id)
        if switchAllowed { current = space.id }
        afterSwitch?()
    }
    func currentSpace(on displayID: String) -> UInt64? { current }
}

final class AgentOriginNavigationTests: XCTestCase {
    private let target = AgentOrigin(displayID: "display", spaceUUID: "project-space")
    private func space(id: UInt64 = 7, ordinal: Int = 2, uuid: String = "project-space", display: String = "display") -> AgentOriginSnapshot.Space {
        .init(uuid: uuid, id: id, ordinal: ordinal, displayID: display)
    }

    func testCaptureUsesSourceForegroundOrUnambiguousSourceSpaceOnly() {
        let other = AgentOrigin(displayID: "other", spaceUUID: "other-space")
        XCTAssertEqual(AgentSpaceCapture.select(windowSpaces: [[target]], foregroundSpace: other), target)
        XCTAssertEqual(AgentSpaceCapture.select(windowSpaces: [[target], [target]], foregroundSpace: nil), target)
        XCTAssertEqual(AgentSpaceCapture.select(windowSpaces: [[target], [other]], foregroundSpace: target), target)
        XCTAssertNil(AgentSpaceCapture.select(windowSpaces: [[target], [other]], foregroundSpace: nil))
        XCTAssertNil(AgentSpaceCapture.select(windowSpaces: [[target, other]], foregroundSpace: target))
        XCTAssertNil(AgentSpaceCapture.select(windowSpaces: [[], [target]], foregroundSpace: nil))
        XCTAssertNil(AgentSpaceCapture.select(windowSpaces: [], foregroundSpace: target))
    }

    @MainActor
    func testNavigatesToCapturedSpaceWithoutWindowBindingAndSurvivesReordering() async {
        let backend = OriginBackendFixture()
        backend.state = .init(permitted: true, spaces: [space(ordinal: 4)])
        let navigation = AgentOriginNavigation(backend: backend, log: { _ in })
        let event = AgentHookEvent(agentID: "codex", source: "source", session: "hidden-session", kind: "Stop", turn: "t", received: Date(), project: "space-widget", origin: target)
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
                      .init(permitted: true, spaces: [space(display: "disconnected")]),
                      .init(permitted: true, spaces: [space(), space(id: 8)])] {
            backend.state = state
            let result = await navigation.navigate(to: target)
            XCTAssertFalse(result)
        }
        XCTAssertTrue(backend.switched.isEmpty)
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
        let event = AgentHookEvent(agentID: "codex", source: "source", session: "sensitive-session-id", kind: "Stop", turn: "t", received: Date(), project: "space-widget", origin: target)
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
