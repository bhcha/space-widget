import AppKit
import ApplicationServices
import Combine

struct DockGeometry: Equatable {
    let frame: CGRect          // Cocoa screen coordinates
    let displayID: String      // display UUID where Dock lives
    let isVisible: Bool        // false when autohide has hidden it
}

final class DockGeometryObserver: ObservableObject {
    @Published private(set) var current: DockGeometry?

    private var dockElement: AXUIElement?
    private var dockPID: pid_t = 0
    private var screenObserver: NSObjectProtocol?
    private var pollTimer: Timer?

    init() {
        attachToDock()
        observeScreenChanges()
        // Poll every 1s as fallback — Dock frame can change without AX notifications
        // (e.g. autohide visibility transitions). Keep this cheap.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let obs = screenObserver { NotificationCenter.default.removeObserver(obs) }
        pollTimer?.invalidate()
    }

    private func attachToDock() {
        // Find Dock process
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return
        }
        dockPID = dock.processIdentifier
        dockElement = AXUIElementCreateApplication(dockPID)
        refresh()
    }

    func refresh() {
        // Re-find Dock if it died/restarted
        if dockElement == nil || !isDockAlive() {
            attachToDock()
        }
        guard let dockApp = dockElement else {
            DispatchQueue.main.async { [weak self] in self?.current = nil }
            return
        }

        // Dock's AXChildren contains "list" elements; the first one is the dock items list.
        // We query position/size of the list element directly.
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockApp, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement],
              let list = children.first else {
            DispatchQueue.main.async { [weak self] in self?.current = nil }
            return
        }

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(list, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(list, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            DispatchQueue.main.async { [weak self] in self?.current = nil }
            return
        }

        var axPos = CGPoint.zero
        var axSize = CGSize.zero
        // swiftlint:disable force_cast
        AXValueGetValue(posRef as! AXValue, .cgPoint, &axPos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &axSize)
        // swiftlint:enable force_cast

        // AX coordinates are top-left origin; convert to Cocoa bottom-left.
        // Find which screen contains the dock's AX rect center.
        let axRect = CGRect(origin: axPos, size: axSize)
        let centerTopLeft = CGPoint(x: axRect.midX, y: axRect.midY)

        // Convert each screen's frame to AX space (top-left) to find containing screen.
        guard !NSScreen.screens.isEmpty else {
            DispatchQueue.main.async { [weak self] in self?.current = nil }
            return
        }

        let globalMaxY = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0

        var containingScreen: NSScreen?
        for screen in NSScreen.screens {
            let fr = screen.frame
            // Convert screen Cocoa frame to AX space: top-left origin, y = globalMaxY - (cocoaY + height)
            let axScreenY = globalMaxY - fr.maxY
            let axScreen = CGRect(x: fr.origin.x, y: axScreenY, width: fr.width, height: fr.height)
            if axScreen.contains(centerTopLeft) {
                containingScreen = screen
                break
            }
        }
        guard let screen = containingScreen,
              let displayID = displayIdentifier(for: screen) else {
            DispatchQueue.main.async { [weak self] in self?.current = nil }
            return
        }

        // Convert dock AX rect to Cocoa for this screen
        let cocoaY = globalMaxY - axRect.maxY
        let cocoaFrame = CGRect(x: axRect.origin.x, y: cocoaY, width: axRect.width, height: axRect.height)

        // Visibility heuristic: if dock has effectively zero height/width (autohide hidden),
        // or size is below a threshold, consider hidden.
        let isVisible = axRect.width > 4 && axRect.height > 4

        let geometry = DockGeometry(frame: cocoaFrame, displayID: displayID, isVisible: isVisible)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.current != geometry {
                self.current = geometry
            }
        }
    }

    private func isDockAlive() -> Bool {
        guard dockPID > 0 else { return false }
        return NSRunningApplication(processIdentifier: dockPID) != nil
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }
}
