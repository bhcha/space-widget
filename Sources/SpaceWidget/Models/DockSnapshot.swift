import Foundation

struct DockSnapshot: Equatable {
    let space: ActiveSpace
    let spaceLabel: String
    let items: [DockItem]           // full DockItem array (not just names/IDs)
    let focusedBundleID: String?
    let capturedAt: Date

    var spaceNumber: Int { space.ordinal }
    var spaceID: UInt64 { space.id }
    var appBundleIDs: [String] { items.map(\.id) }
    var appNames: [String] { items.map(\.name) }

    static func == (lhs: DockSnapshot, rhs: DockSnapshot) -> Bool {
        lhs.space == rhs.space &&
        lhs.spaceLabel == rhs.spaceLabel &&
        lhs.items == rhs.items &&
        lhs.focusedBundleID == rhs.focusedBundleID
    }

    func withFocusedBundleID(_ bundleID: String?) -> DockSnapshot {
        DockSnapshot(space: space, spaceLabel: spaceLabel, items: items.map { item in
            DockItem(id: item.id, name: item.name, icon: item.icon, pid: item.pid,
                     windowCount: item.windowCount, isFocused: item.id == bundleID, isHidden: item.isHidden)
        }, focusedBundleID: bundleID, capturedAt: Date())
    }
}
