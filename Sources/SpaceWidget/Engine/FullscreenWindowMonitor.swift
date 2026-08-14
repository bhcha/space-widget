import AppKit
import Combine

/// Detects apps covering an entire display with a regular window on a desktop space
/// (PowerPoint slideshows, non-native fullscreen video players). These never enter a
/// fullscreen Space, so SpaceMonitor's space-type check cannot see them — and no
/// NSWorkspace notification fires when an app opens a window within itself, so this
/// polls the window list instead.
///
/// A window counts as "covering" when its bounds contain the display's full
/// CGDisplayBounds — including the menu bar strip, which a normally maximized window
/// never overlaps. Owners with permanent display-sized windows (Dock keeps one at
/// layer 20 for Mission Control; Window Server holds transition shields) are excluded,
/// as are this app's own panels.
final class FullscreenWindowMonitor: ObservableObject {
    /// Display identifier strings (same format as `displayIdentifier(for:)`) whose
    /// entire bounds are covered by another app's window.
    @Published private(set) var coveredDisplays: Set<String> = []

    private let timer: DispatchSourceTimer
    private let ownPID = getpid()
    private static let excludedOwners: Set<String> = ["Dock", "Window Server", "WindowManager"]

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
        let covered = Self.detectCoveredDisplays(ownPID: ownPID)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.coveredDisplays != covered else { return }
            swLog("PANEL", "covering-window change \(self.coveredDisplays.sorted()) -> \(covered.sorted())")
            self.coveredDisplays = covered
        }
    }

    private static func detectCoveredDisplays(ownPID: pid_t) -> Set<String> {
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

        var covered: Set<String> = []
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            if excludedOwners.contains(owner) { continue }
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
