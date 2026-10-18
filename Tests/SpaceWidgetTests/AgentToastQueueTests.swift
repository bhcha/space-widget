import XCTest
import AppKit
@testable import SpaceWidget

final class AgentToastQueueTests: XCTestCase {
    private func notice(_ session: String) -> AgentCompletionNotice {
        .init(event: .init(agentID: "codex", source: "queue-fixture", session: session,
            kind: "Stop", turn: session, received: Date()), space: nil, isTest: false)
    }

    @MainActor
    func testStackShowsNewestOnTopAndQueuesBeyondVisibleLimit() throws {
        _ = NSApplication.shared
        let presenter = AgentToastPresenter()
        defer { presenter.clear() }
        let items = (0..<5).map { notice("n\($0)") }
        items.forEach { presenter.show($0) }
        XCTAssertEqual(presenter.visible.map(\.id), [items[2].id, items[1].id, items[0].id])
        XCTAssertEqual(presenter.pending.map(\.id), [items[3].id, items[4].id])
        XCTAssertEqual(presenter.currentNotice?.id, items[2].id)
        for notice in presenter.visible { XCTAssertNotNil(presenter.panel(for: notice.id)) }

        // Closing a lower toast closes its gap and the oldest waiting toast enters on top.
        presenter.dismissCurrent(expectedID: items[1].id)
        XCTAssertEqual(presenter.visible.map(\.id), [items[3].id, items[2].id, items[0].id])
        XCTAssertNil(presenter.panel(for: items[1].id))
        presenter.dismissCurrent(expectedID: items[1].id) // stale dismiss is a no-op
        XCTAssertEqual(presenter.visible.map(\.id), [items[3].id, items[2].id, items[0].id])
        XCTAssertEqual(presenter.pending.map(\.id), [items[4].id])

        presenter.dismissCurrent(expectedID: items[0].id)
        presenter.dismissCurrent(expectedID: items[3].id)
        XCTAssertEqual(presenter.visible.map(\.id), [items[4].id, items[2].id])
        XCTAssertTrue(presenter.pending.isEmpty)
        presenter.dismissCurrent()
        presenter.dismissCurrent()
        XCTAssertTrue(presenter.visible.isEmpty)
    }

    @MainActor
    func testSlotsStackDownwardWithoutOverlap() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1055)
        let frames = (0..<AgentToastPresenter.maximumVisible).map { AgentToastPresenter.frame(slot: $0, in: screen) }
        XCTAssertEqual(frames[0].maxX, screen.maxX - AgentToastPresenter.margin)
        XCTAssertEqual(frames[0].maxY, screen.maxY - AgentToastPresenter.margin)
        for (upper, lower) in zip(frames, frames.dropFirst()) {
            XCTAssertFalse(upper.intersects(lower))
            XCTAssertEqual(upper.minY - lower.maxY, AgentToastPresenter.spacing)
        }
        XCTAssertTrue(screen.contains(frames.last!))
    }

    @MainActor
    func testRepositionedPanelsFollowStackOrder() throws {
        _ = NSApplication.shared
        let presenter = AgentToastPresenter()
        defer { presenter.clear() }
        let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let items = (0..<3).map { notice("p\($0)") }
        items.forEach { presenter.show($0) }
        presenter.dismissCurrent(expectedID: items[1].id)
        // Allow the 0.2s slide to settle; final frames are what matter.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        for (slot, notice) in presenter.visible.enumerated() {
            let panel = try XCTUnwrap(presenter.panel(for: notice.id))
            XCTAssertEqual(panel.frame, AgentToastPresenter.frame(slot: slot, in: screen), "slot \(slot)")
        }
        XCTAssertEqual(presenter.visible.map(\.id), [items[2].id, items[0].id])
    }

    @MainActor
    func testEachToastTimesOutAndNotificationOffClearsTheWholeStack() async throws {
        _ = NSApplication.shared
        let presenter = AgentToastPresenter(displayDuration: .milliseconds(80))
        defer { presenter.clear() }
        let suite = "SpaceWidgetToastQueue." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AgentNotificationModel(defaults: defaults, present: { presenter.show($0) },
            cancelPresentation: { presenter.clear() })
        for session in ["first", "second", "third", "fourth"] { model.receive(notice(session).event) }
        XCTAssertEqual(presenter.visible.map(\.event.session), ["third", "second", "first"])
        for _ in 0..<100 {
            if presenter.visible.first?.event.session == "fourth" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(presenter.visible.first?.event.session, "fourth")
        XCTAssertTrue(presenter.pending.isEmpty)
        model.receive(notice("fifth").event)
        model.notificationsEnabled = false
        XCTAssertTrue(presenter.visible.isEmpty)
        XCTAssertTrue(presenter.pending.isEmpty)
    }

    @MainActor
    func testPresentationBacklogIsBoundedWithoutReplacingVisibleNotices() {
        _ = NSApplication.shared
        let presenter = AgentToastPresenter()
        defer { presenter.clear() }
        let visible = (0..<AgentToastPresenter.maximumVisible).map { notice("visible-\($0)") }
        visible.forEach { presenter.show($0) }
        for index in 0..<(AgentToastPresenter.maximumPending + 3) { presenter.show(notice("bounded-\(index)")) }
        XCTAssertEqual(presenter.pending.count, AgentToastPresenter.maximumPending)
        XCTAssertEqual(presenter.pending.first?.event.session, "bounded-3")
        XCTAssertEqual(presenter.visible.map(\.id), visible.reversed().map(\.id))
    }
}
