import AppKit

final class SpacePanel: NSPanel {
    var onRightClick: ((NSPoint) -> Void)?  // window coordinates

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )

        level = .floating
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces]
        isOpaque = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func rightMouseDown(with event: NSEvent) {
        swLog("PANEL", "rightMouseDown at=\(event.locationInWindow) screen=\(screen?.frame.debugDescription ?? "nil")")
        onRightClick?(event.locationInWindow)
    }

    override func mouseDown(with event: NSEvent) {
        swLog("PANEL", "mouseDown at=\(event.locationInWindow) screen=\(screen?.frame.debugDescription ?? "nil")")
        if event.modifierFlags.contains(.control) {
            onRightClick?(event.locationInWindow)
        } else {
            super.mouseDown(with: event)
        }
    }
}
