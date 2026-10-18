import AppKit
import XCTest
@testable import SpaceWidget

final class FullscreenWindowMonitorTests: XCTestCase {
    private let mainBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
    // Above the main display, to exercise global window-server coordinates.
    private let secondBounds = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
    private let presentingPID: pid_t = 100
    private let overlayPID: pid_t = 200
    private let ownPID: pid_t = 300

    func testNotificationOverlayDoesNotHideWidget() {
        XCTAssertEqual(covered(options: [], windows: [
            window(pid: overlayPID, bounds: mainBounds, layer: 25)
        ]), [])
    }

    func testDragOverlayFromFrontmostAppDoesNotHideWidget() {
        XCTAssertEqual(covered(options: [], windows: [
            window(pid: presentingPID, bounds: mainBounds, layer: 101)
        ]), [])
    }

    func testScreenSizedAppWindowWithDockAvailableDoesNotHideWidget() {
        XCTAssertEqual(covered(options: [], windows: [
            window(pid: presentingPID, bounds: mainBounds)
        ]), [])
    }

    func testPresentationHidingDockHidesOnlyCoveredDisplay() {
        XCTAssertEqual(covered(options: [.hideDock, .hideMenuBar], windows: [
            window(pid: presentingPID, bounds: secondBounds)
        ]), ["second"])
    }

    func testPresentationAutoHidingDockIsRecognized() {
        XCTAssertEqual(covered(options: [.autoHideDock, .autoHideMenuBar], windows: [
            window(pid: presentingPID, bounds: mainBounds)
        ]), ["main"])
    }

    func testOtherAppsOverlaysDoNotHideAnotherDisplayDuringPresentation() {
        XCTAssertEqual(covered(options: [.hideDock], windows: [
            window(pid: presentingPID, bounds: mainBounds),
            window(pid: overlayPID, bounds: secondBounds, layer: 25),
            window(pid: ownPID, bounds: secondBounds, layer: 3)
        ]), ["main"])
    }

    func testMaximizedAndTransparentWindowsDoNotCountAsPresentationCoverage() {
        let maximizedBounds = CGRect(x: 0, y: 25, width: 1440, height: 875)
        XCTAssertEqual(covered(options: [.hideDock], windows: [
            window(pid: presentingPID, bounds: maximizedBounds),
            window(pid: presentingPID, bounds: mainBounds, alpha: 0),
            window(pid: presentingPID, bounds: secondBounds, layer: -1)
        ]), [])
    }

    func testDockBecomingAvailableRestoresWidgetEvenIfWindowRemains() {
        let windows = [window(pid: presentingPID, bounds: mainBounds)]
        XCTAssertEqual(covered(options: [.hideDock], windows: windows), ["main"])
        XCTAssertEqual(covered(options: [], windows: windows), [])
    }

    func testMissingOrOwnFrontmostAppDoesNotHideWidget() {
        for pid in [nil, ownPID] as [pid_t?] {
            XCTAssertEqual(FullscreenWindowMonitor.coveredDisplays(
                presentationOptions: [.hideDock],
                frontmostPID: pid,
                ownPID: ownPID,
                displays: [(uuid: "main", bounds: mainBounds)],
                windowList: [window(pid: ownPID, bounds: mainBounds)]
            ), [])
        }
    }

    private func covered(
        options: NSApplication.PresentationOptions,
        windows: [[String: Any]]
    ) -> Set<String> {
        FullscreenWindowMonitor.coveredDisplays(
            presentationOptions: options,
            frontmostPID: presentingPID,
            ownPID: ownPID,
            displays: [(uuid: "main", bounds: mainBounds), (uuid: "second", bounds: secondBounds)],
            windowList: windows
        )
    }

    private func window(
        pid: pid_t,
        bounds: CGRect,
        layer: Int = 0,
        alpha: Double = 1
    ) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: [
                "X": bounds.minX, "Y": bounds.minY,
                "Width": bounds.width, "Height": bounds.height
            ]
        ]
    }
}
