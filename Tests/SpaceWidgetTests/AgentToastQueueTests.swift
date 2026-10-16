import XCTest
import AppKit
@testable import SpaceWidget

final class AgentToastQueueTests: XCTestCase {
    private func notice(_ session: String) -> AgentCompletionNotice {
        .init(event: .init(agentID: "codex", source: "queue-fixture", session: session,
            kind: "Stop", turn: session, received: Date()), space: nil, isTest: false)
    }

    @MainActor
    func testBurstRemainsFIFOAndStaleDismissCannotCloseNextNotice() throws {
        _ = NSApplication.shared
        let presenter = AgentToastPresenter()
        defer { presenter.clear() }
        let items = [notice("first"), notice("second"), notice("third")]
        items.forEach { presenter.show($0) }
        XCTAssertEqual(presenter.currentNotice?.id, items[0].id)
        XCTAssertEqual(presenter.pending.map(\.id), [items[1].id, items[2].id])
        presenter.dismissCurrent(expectedID: items[0].id)
        XCTAssertEqual(presenter.currentNotice?.id, items[1].id)
        presenter.dismissCurrent(expectedID: items[0].id)
        XCTAssertEqual(presenter.currentNotice?.id, items[1].id)
        presenter.dismissCurrent(expectedID: items[1].id)
        XCTAssertEqual(presenter.currentNotice?.id, items[2].id)
        presenter.dismissCurrent()
        XCTAssertNil(presenter.currentNotice)
        XCTAssertTrue(presenter.pending.isEmpty)
    }

    @MainActor
    func testTimeoutAdvancesAndNotificationOffClearsTheWholeQueue() async throws {
        _ = NSApplication.shared
        let presenter = AgentToastPresenter(displayDuration: .milliseconds(80))
        defer { presenter.clear() }
        let suite = "SpaceWidgetToastQueue." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AgentNotificationModel(defaults: defaults, present: { presenter.show($0) },
            cancelPresentation: { presenter.clear() })
        model.receive(notice("first").event)
        model.receive(notice("second").event)
        model.receive(notice("third").event)
        for _ in 0..<100 {
            if presenter.currentNotice?.event.session != "first" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(presenter.currentNotice?.event.session, "second")
        model.notificationsEnabled = false
        XCTAssertNil(presenter.currentNotice)
        XCTAssertTrue(presenter.pending.isEmpty)
    }

    @MainActor
    func testPresentationBacklogIsBoundedWithoutReplacingVisibleNotice() {
        _ = NSApplication.shared
        let presenter = AgentToastPresenter()
        defer { presenter.clear() }
        let active = notice("active")
        presenter.show(active)
        for index in 0..<(AgentToastPresenter.maximumPending + 3) { presenter.show(notice("bounded-\(index)")) }
        XCTAssertEqual(presenter.pending.count, AgentToastPresenter.maximumPending)
        XCTAssertEqual(presenter.currentNotice?.id, active.id)
    }
}
