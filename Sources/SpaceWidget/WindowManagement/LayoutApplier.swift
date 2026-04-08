import AppKit
import ApplicationServices

final class LayoutApplier {
    func apply(_ template: LayoutTemplate) {
        guard let screenFrame = ScreenGeometry.mainScreenAXFrame() else { return }

        for zone in template.zones {
            guard let bundleID = zone.assignedAppBundleID else { continue }
            let targetRect = zone.rect.resolve(in: screenFrame)

            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                // App already running — position its window immediately
                positionWindow(of: app, to: targetRect)
            } else {
                // App not running — launch and position after launch
                launchAndPosition(bundleID: bundleID, targetRect: targetRect)
            }
        }
    }

    // MARK: - Private

    private func positionWindow(of app: NSRunningApplication, to rect: CGRect) {
        guard let window = firstWindow(of: app) else { return }
        window.setFrame(rect)
    }

    private func launchAndPosition(bundleID: String, targetRect: CGRect) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] app, error in
            guard let self = self, let app = app, error == nil else { return }
            // Wait briefly for the app to create its window, then position
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.positionWindow(of: app, to: targetRect)
            }
        }
    }

    private func firstWindow(of app: NSRunningApplication) -> WindowElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Try focused window first
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success {
            return WindowElement(windowRef as! AXUIElement)
        }

        // Fallback to first window in list
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let first = windows.first
        else { return nil }

        return WindowElement(first)
    }
}
