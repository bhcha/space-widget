import AppKit

/// NSView subclass that accepts first mouse events so clicks register on the
/// non-activating panel without requiring a prior click to focus it.
final class FirstMouseView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

final class DockPanel: NSPanel {

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Panel behavior
        self.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        self.level = .floating
        self.hidesOnDeactivate = false

        // Transparency
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false

        // Don't steal focus
        self.acceptsMouseMovedEvents = true
        self.ignoresMouseEvents = false

        // Allow drag to reposition
        self.isMovableByWindowBackground = true
        self.isMovable = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
