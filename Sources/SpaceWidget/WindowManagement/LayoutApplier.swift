import AppKit
import ApplicationServices

final class LayoutApplier {
    func apply(_ template: LayoutTemplate, launchClosedApps: Bool = false) {
        guard let screenFrame = ScreenGeometry.mainScreenAXFrame() else { return }

        // Track which apps we've already handled to avoid duplicates
        var handledBundleIDs = Set<String>()

        for zone in template.zones {
            guard let bundleID = zone.assignedAppBundleID else { continue }

            // Compute target rect using the same calculation as window snapping
            let params = CalculationParams(windowFrame: screenFrame, screenFrame: screenFrame)
            let calculation = WindowCalculationFactory.calculation(for: zone.action)
            let result = calculation.calculate(params, action: zone.action)
            let targetRect = result.rect

            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                // App is running — find a window on the current space, preferring the main screen
                if let window = firstWindowOnCurrentSpace(of: app, preferringScreen: screenFrame) {
                    window.setFrame(targetRect)
                } else if let window = firstWindowOnAnyCurrentSpace(of: app) {
                    // Window exists on another display — move it to the target position
                    window.setFrame(targetRect)
                } else if !handledBundleIDs.contains(bundleID) {
                    // App running but no window at all — open new window
                    handledBundleIDs.insert(bundleID)
                    openNewWindowAndPosition(app: app, targetRect: targetRect, screenFrame: screenFrame)
                }
            } else if launchClosedApps && !handledBundleIDs.contains(bundleID) {
                // App not running — launch it
                handledBundleIDs.insert(bundleID)
                launchAndPosition(bundleID: bundleID, targetRect: targetRect, screenFrame: screenFrame)
            }
        }
    }

    // MARK: - Private

    /// Find a window of the given app on the current space.
    /// When `preferringScreen` is provided, prefer windows already on that screen
    /// to avoid repositioning windows from other displays unnecessarily.
    /// If no window is on the preferred screen, returns any window on the current
    /// space (it will be repositioned to the target rect on the main screen).
    private func firstWindowOnCurrentSpace(of app: NSRunningApplication, preferringScreen screenFrame: CGRect? = nil) -> WindowElement? {
        var allWindows: [AXUIElement] = []
        forEachWindowOnCurrentSpace(pid: app.processIdentifier) { _, axWindow, _ in
            allWindows.append(axWindow)
            return false // collect all, don't stop
        }
        guard !allWindows.isEmpty else { return nil }

        // If a preferred screen is specified, prefer windows already on that screen
        if let screenFrame = screenFrame {
            for axWindow in allWindows {
                let element = WindowElement(axWindow)
                if let windowFrame = element.frame, screenFrame.intersects(windowFrame) {
                    return element
                }
            }
        }

        // Fall back to first window found (will be repositioned to main screen)
        return WindowElement(allWindows[0])
    }

    /// Find a window of the app on any display's current space.
    /// Used as fallback when the main display's space has no window — the app may
    /// have a window on the extension display's current space (different spaceID
    /// when "Displays have separate Spaces" is on). Repositioning that window to
    /// main screen coordinates effectively moves it across displays.
    private func firstWindowOnAnyCurrentSpace(of app: NSRunningApplication) -> WindowElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return nil }

        // Collect current spaceIDs for ALL displays
        let cid = CGSMainConnectionID()
        var currentSpaceIDs = Set<UInt64>()
        if let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: AnyObject]] {
            for display in displays {
                if let currentSpace = display["Current Space"] as? [String: AnyObject],
                   let sid = (currentSpace["ManagedSpaceID"] as? UInt64) ?? (currentSpace["id64"] as? UInt64) {
                    currentSpaceIDs.insert(sid)
                }
            }
        }

        for axWindow in axWindows {
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(axWindow, &wid) == .success else { continue }
            guard let spaces = CGSCopySpacesForWindows(cid, 0x7, [wid] as CFArray) as? [UInt64] else { continue }
            // Window must be on at least one display's current space and not minimized
            if !spaces.isEmpty && !currentSpaceIDs.isDisjoint(with: spaces) {
                var minimizedRef: CFTypeRef?
                let isMinimized = AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef) == .success
                    && (minimizedRef as? Bool) == true
                if !isMinimized {
                    return WindowElement(axWindow)
                }
            }
        }
        return nil
    }

    private func openNewWindowAndPosition(app: NSRunningApplication, targetRect: CGRect, screenFrame: CGRect) {
        let pid = app.processIdentifier
        AppActions.openNewWindow(pid: pid)

        // Poll for the new window to appear on current space
        pollForWindow(app: app, targetRect: targetRect, screenFrame: screenFrame, attempts: 0)
    }

    private func pollForWindow(app: NSRunningApplication, targetRect: CGRect, screenFrame: CGRect, attempts: Int) {
        if let window = firstWindowOnCurrentSpace(of: app, preferringScreen: screenFrame) {
            window.setFrame(targetRect)
            return
        }
        guard attempts < 20 else { return } // give up after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.pollForWindow(app: app, targetRect: targetRect, screenFrame: screenFrame, attempts: attempts + 1)
        }
    }

    private func launchAndPosition(bundleID: String, targetRect: CGRect, screenFrame: CGRect) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] app, error in
            guard let self = self, let app = app, error == nil else { return }
            // Wait for the app to initialize, then check for window on current space
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if self.firstWindowOnCurrentSpace(of: app, preferringScreen: screenFrame) == nil {
                    AppActions.openNewWindow(pid: app.processIdentifier)
                }
                self.pollForWindow(app: app, targetRect: targetRect, screenFrame: screenFrame, attempts: 0)
            }
        }
    }
}
