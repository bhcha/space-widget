import AppKit
import ApplicationServices

final class WindowElement {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    /// Get the frontmost window of the frontmost app
    static func getFrontWindow() -> WindowElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        ensureAXEnabled(appElement)
        var windowRef: CFTypeRef?
        // Try focused window first
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success {
            return WindowElement(windowRef as! AXUIElement)
        }
        // Fallback to first window
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let first = windows.first else { return nil }
        return WindowElement(first)
    }

    var position: CGPoint? {
        get {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref) == .success else { return nil }
            var point = CGPoint.zero
            AXValueGetValue(ref as! AXValue, .cgPoint, &point)
            return point
        }
        set {
            guard var point = newValue else { return }
            let value = AXValueCreate(.cgPoint, &point)!
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
    }

    var size: CGSize? {
        get {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success else { return nil }
            var size = CGSize.zero
            AXValueGetValue(ref as! AXValue, .cgSize, &size)
            return size
        }
        set {
            guard var size = newValue else { return }
            let value = AXValueCreate(.cgSize, &size)!
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
    }

    var frame: CGRect? {
        guard let pos = position, let sz = size else { return nil }
        return CGRect(origin: pos, size: sz)
    }

    /// Set window frame. Sets size first, then position, then size again
    /// (handles cross-display moves where size constraints differ)
    func setFrame(_ rect: CGRect) {
        size = rect.size
        position = rect.origin
        size = rect.size  // re-set in case position change affected constraints
    }

    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
}
