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
    func testDeckOverlapsAtTheSpaceLabelAnchorAndFansOutWithoutOverlap() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1920, height: 1055)
        let anchor = AgentToastPresenter.anchor(screenFrame: screen, visibleFrame: visibleFrame)
        XCTAssertEqual(anchor, SpaceLabelOverlay.destination(in: screen, visibleFrame: visibleFrame))
        let front = AgentToastPresenter.frame(position: 0, expanded: false, anchor: anchor)
        XCTAssertEqual(front.size, SpaceLabelOverlay.bubbleSize)
        XCTAssertEqual(front.midX, anchor.x, accuracy: 0.5)
        XCTAssertEqual(front.midY, anchor.y, accuracy: 0.5)
        let collapsed = (0..<AgentToastPresenter.maximumVisible).map { AgentToastPresenter.frame(position: $0, expanded: false, anchor: anchor) }
        for (upper, lower) in zip(collapsed, collapsed.dropFirst()) {
            XCTAssertEqual(upper.minY - lower.minY, AgentToastPresenter.peek, "Each card behind peeks below")
            XCTAssertTrue(upper.intersects(lower))
        }
        let fanned = (0..<AgentToastPresenter.maximumVisible).map { AgentToastPresenter.frame(position: $0, expanded: true, anchor: anchor) }
        for (upper, lower) in zip(fanned, fanned.dropFirst()) {
            XCTAssertFalse(upper.intersects(lower))
            XCTAssertEqual(upper.minY - lower.maxY, AgentToastPresenter.spacing)
        }
        // A display offset from the origin keeps the same relative anchor.
        let offset = AgentToastPresenter.anchor(screenFrame: screen.offsetBy(dx: 1920, dy: 0), visibleFrame: visibleFrame.offsetBy(dx: 1920, dy: 0))
        XCTAssertEqual(offset, CGPoint(x: anchor.x + 1920, y: anchor.y))
    }

    @MainActor
    func testRepositionedPanelsFollowDeckOrderBelowTheSpaceLabelLevel() throws {
        _ = NSApplication.shared
        let presenter = AgentToastPresenter()
        defer { presenter.clear() }
        let screen = try XCTUnwrap(NSScreen.main)
        let anchor = AgentToastPresenter.anchor(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let items = (0..<3).map { notice("p\($0)") }
        items.forEach { presenter.show($0) }
        presenter.dismissCurrent(expectedID: items[1].id)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
        func assertFrames(expanded: Bool, shift: Int = 0, file: StaticString = #filePath, line: UInt = #line) throws {
            for (index, notice) in presenter.visible.enumerated() {
                let panel = try XCTUnwrap(presenter.panel(for: notice.id))
                XCTAssertEqual(panel.frame, AgentToastPresenter.frame(position: index + shift, expanded: expanded, anchor: anchor),
                               "card \(index)", file: file, line: line)
                XCTAssertLessThan(panel.level, SpacePanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true).level,
                                  file: file, line: line)
            }
        }
        settle()
        XCTAssertEqual(presenter.visible.map(\.id), [items[2].id, items[0].id])
        try assertFrames(expanded: false)
        presenter.setExpanded(true)
        settle()
        try assertFrames(expanded: true)
        presenter.setExpanded(false)
        presenter.setSpaceLabelInFront(true)
        settle()
        try assertFrames(expanded: false, shift: 1)
    }

    @MainActor
    func testSpaceLabelInFrontPausesTimersAndNewCardsWaitBehindIt() async throws {
        _ = NSApplication.shared
        let presenter = AgentToastPresenter(displayDuration: .milliseconds(150))
        defer { presenter.clear() }
        let first = notice("first")
        presenter.show(first)
        presenter.setSpaceLabelInFront(true)
        let paused = try XCTUnwrap(presenter.timeRemaining(for: first.id))
        let second = notice("second")
        presenter.show(second) // arrives while the label is showing
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(presenter.visible.map(\.id), [second.id, first.id], "No card expires behind the label")
        XCTAssertEqual(presenter.timeRemaining(for: first.id), paused)
        XCTAssertEqual(presenter.timeRemaining(for: second.id), .milliseconds(150))
        presenter.setSpaceLabelInFront(false)
        for _ in 0..<200 where !presenter.visible.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(presenter.visible.isEmpty, "Timers resume once the label leaves")
    }

    @MainActor
    func testArrivingAtATasksSpaceDismissesOnlyThatCard() {
        _ = NSApplication.shared
        let presenter = AgentToastPresenter()
        defer { presenter.clear() }
        func card(_ uuid: String) -> AgentCompletionNotice {
            .init(event: notice(uuid).event, space: uuid, isTest: false, origin: .init(displayID: "d", spaceUUID: uuid))
        }
        let work = card("work"), data = card("data")
        let unknown = notice("unknown")
        [work, data, unknown].forEach { presenter.show($0) }
        presenter.spaceDidBecomeActive(uuid: "work")
        XCTAssertEqual(presenter.visible.map(\.id), [unknown.id, data.id])
        presenter.spaceDidBecomeActive(uuid: "elsewhere")
        XCTAssertEqual(presenter.visible.count, 2)
    }

    @MainActor
    func testCardAppearanceNamesStateAndTone() {
        let origin = AgentOrigin(displayID: "d", spaceUUID: "s")
        let event = notice("a").event
        let done = AgentToastAppearance(.init(event: event, space: "Work · Space 2", isTest: false, origin: origin))
        XCTAssertEqual(done.tone, .done)
        XCTAssertEqual(done.state, "Done")
        let failed = AgentToastAppearance(.init(event: event, space: nil, isTest: false, origin: origin, navigationIssue: "Check settings."))
        XCTAssertEqual(failed.tone, .warning)
        XCTAssertEqual(failed.detail, "Check settings.")
        let unknown = AgentToastAppearance(.init(event: event, space: nil, isTest: false))
        XCTAssertEqual(unknown.state, "Unknown Space")
        XCTAssertEqual(unknown.tone, .warning)
        let preview = AgentToastAppearance(.init(event: event, space: nil, isTest: true, origin: origin))
        XCTAssertEqual(preview.tone, .preview)
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
