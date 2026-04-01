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
    // Main bar background
    static let barBg = Color(hex: 0x2c2e34, opacity: 0.94)

    // Background layers
    static let bg1 = Color(hex: 0x363944)
    static let bg2 = Color(hex: 0x414550)

    // Text colors
    static let white = Color(hex: 0xe2e2e3)
    static let grey = Color(hex: 0x7f8490)

    // Accent
    static let highlight = Color(hex: 0x7aa2f7)

    // Cluster
    static let clusterBg = Color(hex: 0x1d2027, opacity: 0.77)
    static let clusterBorder = Color.white.opacity(0.094)

    // Chip
    static let chipBg = Color(hex: 0x383c45)

    // Space label color
    static let spaceLabel = Color(hex: 0xc9ccd3)
}
