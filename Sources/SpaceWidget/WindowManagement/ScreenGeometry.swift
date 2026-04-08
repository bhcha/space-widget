import AppKit

enum ScreenGeometry {
    /// Find the screen that contains the largest portion of the given AX-coordinate rect.
    static func screenContaining(_ axRect: CGRect) -> NSScreen? {
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
    static func convertToCocoaCoordinates(_ rect: CGRect) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else { return rect }
        let primaryHeight = primaryScreen.frame.height
        let cocoaY = primaryHeight - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: cocoaY, width: rect.width, height: rect.height)
    }

    /// Convert an NSScreen rect (Cocoa bottom-left origin) to AX coordinates (top-left origin).
    static func convertToAXCoordinates(_ rect: CGRect, screen: NSScreen) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else { return rect }
        let primaryHeight = primaryScreen.frame.height
        let axY = primaryHeight - rect.maxY
        return CGRect(x: rect.origin.x, y: axY, width: rect.width, height: rect.height)
    }

    /// Returns the main screen's visible frame in AX coordinates.
    static func mainScreenAXFrame() -> CGRect? {
        guard let screen = NSScreen.main else { return nil }
        return convertToAXCoordinates(screen.visibleFrame, screen: screen)
    }
}
