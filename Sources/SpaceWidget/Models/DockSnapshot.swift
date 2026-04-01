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
}
