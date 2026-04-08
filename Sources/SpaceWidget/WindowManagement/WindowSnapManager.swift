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
        guard let screen = ScreenGeometry.screenContaining(windowFrame) else { return }

        // NSScreen.visibleFrame uses bottom-left origin (Cocoa coordinates).
        // AX API uses top-left origin (flipped). Convert the visibleFrame to
        // AX coordinates so calculations and setFrame() speak the same system.
        let screenFrame = ScreenGeometry.convertToAXCoordinates(screen.visibleFrame, screen: screen)

        let params = CalculationParams(windowFrame: windowFrame, screenFrame: screenFrame)
        let calculation = WindowCalculationFactory.calculation(for: action)
        let result = calculation.calculate(params, action: action)

        windowElement.setFrame(result.rect)
    }
}
