import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

enum Theme {
    static let barBg = Color.black.opacity(0.45)
    static let bg1 = Color.white.opacity(0.08)
    static let bg2 = Color.white.opacity(0.12)
    static let white = Color.white.opacity(0.9)
    static let grey = Color.white.opacity(0.5)
    static let highlight = Color.white.opacity(0.4)
    static let clusterBg = Color.black.opacity(0.15)
    static let clusterBorder = Color.white.opacity(0.1)
    static let chipBg = Color.white.opacity(0.1)
    static let spaceLabel = Color.white.opacity(0.55)
}
