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
                // App is running — check if it has a window on the current space
                if let window = firstWindowOnCurrentSpace(of: app) {
                    window.setFrame(targetRect)
                } else if !handledBundleIDs.contains(bundleID) {
                    // App running but no window on current space — open new window
                    handledBundleIDs.insert(bundleID)
                    openNewWindowAndPosition(app: app, targetRect: targetRect)
                }
            } else if launchClosedApps && !handledBundleIDs.contains(bundleID) {
                // App not running — launch it
                handledBundleIDs.insert(bundleID)
                launchAndPosition(bundleID: bundleID, targetRect: targetRect)
            }
        }
    }

    // MARK: - Private

    private func firstWindowOnCurrentSpace(of app: NSRunningApplication) -> WindowElement? {
        var found: AXUIElement?
        forEachWindowOnCurrentSpace(pid: app.processIdentifier) { _, axWindow, _ in
            found = axWindow
            return true // stop at first match
        }
        guard let axWindow = found else { return nil }
        return WindowElement(axWindow)
    }

    private func openNewWindowAndPosition(app: NSRunningApplication, targetRect: CGRect) {
        let pid = app.processIdentifier
        AppActions.openNewWindow(pid: pid)

        // Poll for the new window to appear on current space
        pollForWindow(app: app, targetRect: targetRect, attempts: 0)
    }

    private func pollForWindow(app: NSRunningApplication, targetRect: CGRect, attempts: Int) {
        if let window = firstWindowOnCurrentSpace(of: app) {
            window.setFrame(targetRect)
            return
        }
        guard attempts < 20 else { return } // give up after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.pollForWindow(app: app, targetRect: targetRect, attempts: attempts + 1)
        }
    }

    private func launchAndPosition(bundleID: String, targetRect: CGRect) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] app, error in
            guard let self = self, let app = app, error == nil else { return }
            // Wait for the app to initialize, then check for window on current space
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if self.firstWindowOnCurrentSpace(of: app) == nil {
                    AppActions.openNewWindow(pid: app.processIdentifier)
                }
                self.pollForWindow(app: app, targetRect: targetRect, attempts: 0)
            }
        }
    }
}
