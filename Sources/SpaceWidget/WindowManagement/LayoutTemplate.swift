import Foundation

struct NormalizedRect: Codable, Equatable {
    var x: CGFloat      // 0~1
    var y: CGFloat      // 0~1
    var width: CGFloat   // 0~1
    var height: CGFloat  // 0~1

    func resolve(in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.minX + screenFrame.width * x,
            y: screenFrame.minY + screenFrame.height * y,
            width: screenFrame.width * width,
            height: screenFrame.height * height
        )
    }
}

struct LayoutZone: Codable, Identifiable, Equatable {
    let id: UUID
    var rect: NormalizedRect
    var assignedAppBundleID: String?
}

struct LayoutTemplate: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var shortcut: ShortcutBinding?
    var zones: [LayoutZone]
}
