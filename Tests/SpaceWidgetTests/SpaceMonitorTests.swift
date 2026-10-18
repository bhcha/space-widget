import AppKit
import Combine
import XCTest
@testable import SpaceWidget

final class SpaceMonitorTests: XCTestCase {
    @MainActor
    func testNotificationPublishesImmediatelyAndReconciliationDoesNotDuplicate() async throws {
        let center = NotificationCenter()
        var current = ActiveSpace(id: 1, ordinal: 1)
        let monitor = SpaceMonitor(notificationCenter: center, spaceResolver: { (["display": current], []) })
        var changes: [UInt64] = []
        let subscription = monitor.$displaySpaces.dropFirst().sink { changes.append($0["display"]!.id) }
        defer { subscription.cancel() }
        current = ActiveSpace(id: 2, ordinal: 2)
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(changes, [2], "The label must not wait for the 100ms trailing read")
        current = ActiveSpace(id: 3, ordinal: 3)
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(changes, [2, 3])
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(changes, [2, 3], "Reconciliation must not reset the label's hold timer")
    }

    @MainActor
    func testTrailingReadRecoversMetadataThatWasNotReadyAtNotification() async throws {
        let center = NotificationCenter()
        var current = ActiveSpace(id: 1, ordinal: 1)
        let monitor = SpaceMonitor(notificationCenter: center, spaceResolver: { (["display": current], []) })
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(monitor.displaySpaces["display"]?.id, 1)
        current = ActiveSpace(id: 2, ordinal: 2)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(monitor.displaySpaces["display"]?.id, 2)
    }

    @MainActor
    func testFullscreenStateIsCurrentWhenDesktopChangePublishes() {
        let center = NotificationCenter()
        var fullscreen = false
        let monitor = SpaceMonitor(notificationCenter: center, spaceResolver: {
            (fullscreen ? [:] : ["display": ActiveSpace(id: 1, ordinal: 1)], fullscreen ? ["display"] : [])
        })
        var fullscreenAtPublication: [Bool] = []
        let subscription = monitor.$displaySpaces.dropFirst().sink { _ in
            fullscreenAtPublication.append(monitor.fullscreenDisplays.contains("display"))
        }
        defer { subscription.cancel() }
        fullscreen = true
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        fullscreen = false
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(fullscreenAtPublication, [true, false])
    }
}
