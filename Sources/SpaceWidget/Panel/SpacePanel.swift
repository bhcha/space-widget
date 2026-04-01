import AppKit

final class SpacePanel: NSPanel {
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

        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.backstopMenu)))
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces]
        isOpaque = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
