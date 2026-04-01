import AppKit

struct DockItem: Identifiable, Hashable {
    let id: String        // bundle identifier
    let name: String      // app display name
    let icon: NSImage     // real app icon from NSRunningApplication
    let pid: pid_t
    var windowCount: Int
    var isFocused: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(isFocused)
        hasher.combine(windowCount)
    }

    static func == (lhs: DockItem, rhs: DockItem) -> Bool {
        lhs.id == rhs.id && lhs.isFocused == rhs.isFocused && lhs.windowCount == rhs.windowCount && lhs.name == rhs.name
    }
}
