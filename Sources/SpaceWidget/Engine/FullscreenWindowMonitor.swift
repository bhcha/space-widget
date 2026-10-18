import AppKit
import Combine

/// Detects desktop-space presentations that actually suppress the Dock (such as a
/// PowerPoint slideshow). Native fullscreen Spaces are handled by SpaceMonitor.
///
/// Screen-sized windows alone are not a fullscreen signal: notification and drag
/// overlays can have those bounds while leaving the Dock available. Require the
/// active app's system presentation options to hide the Dock, then use only that
/// app's covering windows to identify the affected displays. Ordinary Dock autohide
/// is a user preference, not an app presentation option.
final class FullscreenWindowMonitor: ObservableObject {
    /// Displays covered by the active app while its presentation hides the Dock.
    @Published private(set) var coveredDisplays: Set<String> = []

    private let timer: DispatchSourceTimer
    private let ownPID = getpid()

    init(interval: TimeInterval = 1.0) {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
    }

    deinit {
        timer.cancel()
    }

    private func poll() {
        // AppKit state belongs on the main thread; keep the window-list scan off it.
        let (options, frontmostPID) = DispatchQueue.main.sync {
            (NSApp.currentSystemPresentationOptions,
             NSWorkspace.shared.frontmostApplication?.processIdentifier)
        }
        let covered = Self.detectCoveredDisplays(
            presentationOptions: options,
            frontmostPID: frontmostPID,
            ownPID: ownPID
        )
        DispatchQueue.main.async { [weak self] in
            guard let self, self.coveredDisplays != covered else { return }
            swLog("PANEL", "dock-hiding presentation change \(self.coveredDisplays.sorted()) -> \(covered.sorted()) options=\(options.rawValue) frontmostPID=\(frontmostPID ?? 0)")
            self.coveredDisplays = covered
        }
    }

    private static func detectCoveredDisplays(
        presentationOptions: NSApplication.PresentationOptions,
        frontmostPID: pid_t?,
        ownPID: pid_t
    ) -> Set<String> {
        // Also avoids a window-server query during ordinary desktop use.
        guard presentationOptions.contains(.hideDock) || presentationOptions.contains(.autoHideDock),
              let frontmostPID, frontmostPID != ownPID else { return [] }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displayIDs, &displayCount) == .success, displayCount > 0 else {
            return []
        }
        let displays: [(uuid: String, bounds: CGRect)] = (0..<Int(displayCount)).compactMap { index in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayIDs[index]),
                  let uuidString = CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String?
            else { return nil }
            return (uuid: uuidString, bounds: CGDisplayBounds(displayIDs[index]))
        }

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return coveredDisplays(
            presentationOptions: presentationOptions,
            frontmostPID: frontmostPID,
            ownPID: ownPID,
            displays: displays,
            windowList: windowList
        )
    }

    static func coveredDisplays(
        presentationOptions: NSApplication.PresentationOptions,
        frontmostPID: pid_t?,
        ownPID: pid_t,
        displays: [(uuid: String, bounds: CGRect)],
        windowList: [[String: Any]]
    ) -> Set<String> {
        guard presentationOptions.contains(.hideDock) || presentationOptions.contains(.autoHideDock),
              let frontmostPID, frontmostPID != ownPID else { return [] }

        var covered: Set<String> = []
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == frontmostPID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.1 else { continue }
            let rect = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            for display in displays where rect.contains(display.bounds) {
                covered.insert(display.uuid)
            }
        }
        return covered
    }
}
