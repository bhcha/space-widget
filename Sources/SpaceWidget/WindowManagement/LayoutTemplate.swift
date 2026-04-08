import Foundation

struct LayoutZone: Codable, Identifiable, Equatable {
    let id: UUID
    var action: WindowAction  // WindowAction is already Codable (String rawValue enum)
    var assignedAppBundleID: String?
}

struct LayoutTemplate: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var shortcut: ShortcutBinding?
    var zones: [LayoutZone]
}
