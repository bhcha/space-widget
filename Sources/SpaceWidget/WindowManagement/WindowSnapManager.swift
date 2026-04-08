import AppKit

final class WindowSnapManager {
    func execute(_ action: WindowAction) {
        guard let windowElement = WindowElement.getFrontWindow() else { return }

        // Minimize uses AX attribute, not frame calculation
        if action == .minimize {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(windowElement.element, kAXMinimizedAttribute as CFString, &value)
            let isMinimized = (value as? Bool) ?? false
            AXUIElementSetAttributeValue(windowElement.element, kAXMinimizedAttribute as CFString, (!isMinimized) as CFTypeRef)
            return
        }

        guard let windowFrame = windowElement.frame else { return }

        // Get the screen containing the window
        guard let screen = screenContaining(windowFrame) else { return }

        // NSScreen.visibleFrame uses bottom-left origin (Cocoa coordinates).
        // AX API uses top-left origin (flipped). Convert the visibleFrame to
        // AX coordinates so calculations and setFrame() speak the same system.
        let screenFrame = convertToAXCoordinates(screen.visibleFrame, screen: screen)

        let params = CalculationParams(windowFrame: windowFrame, screenFrame: screenFrame)
        let calculation = WindowCalculationFactory.calculation(for: action)
        let result = calculation.calculate(params, action: action)

        windowElement.setFrame(result.rect)
    }

    // MARK: - Private helpers

    private func screenContaining(_ axRect: CGRect) -> NSScreen? {
        // Convert AX rect (top-left origin) to Cocoa (bottom-left origin) for comparison with NSScreen.frame
        let cocoaRect = convertToCocoaCoordinates(axRect)
        var bestScreen = NSScreen.main
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let intersection = screen.frame.intersection(cocoaRect)
            if !intersection.isNull {
                let area = intersection.width * intersection.height
                if area > bestArea {
                    bestArea = area
                    bestScreen = screen
                }
            }
        }
        return bestScreen
    }

    /// Convert AX coordinates (top-left origin) to Cocoa coordinates (bottom-left origin).
    private func convertToCocoaCoordinates(_ rect: CGRect) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else { return rect }
        let primaryHeight = primaryScreen.frame.height
        let cocoaY = primaryHeight - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: cocoaY, width: rect.width, height: rect.height)
    }

    /// Convert an NSScreen rect (Cocoa bottom-left origin) to AX coordinates (top-left origin).
    /// The primary screen's height anchors the flip.
    private func convertToAXCoordinates(_ rect: CGRect, screen: NSScreen) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else { return rect }
        let primaryHeight = primaryScreen.frame.height
        // Flip: AX y = primaryHeight - (cocoaY + height)
        let axY = primaryHeight - rect.maxY
        return CGRect(x: rect.origin.x, y: axY, width: rect.width, height: rect.height)
    }
}
