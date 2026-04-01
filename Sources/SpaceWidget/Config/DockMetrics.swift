import Foundation
import AppKit

struct DockMetrics {
    let barHeight: CGFloat
    let iconSize: CGFloat
    let hoverIconSize: CGFloat
    let badgeHeight: CGFloat
    let badgeChipHeight: CGFloat
    let yOffset: CGFloat
    let cornerRadius: CGFloat

    static func current() -> DockMetrics {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")

        let tileSize: CGFloat
        if let tile = dockDefaults?.object(forKey: "tilesize") as? NSNumber {
            tileSize = CGFloat(tile.doubleValue)
        } else {
            tileSize = 48
        }

        let largeSize: CGFloat
        if let large = dockDefaults?.object(forKey: "largesize") as? NSNumber {
            largeSize = CGFloat(large.doubleValue)
        } else {
            largeSize = tileSize
        }

        let magnification: Bool
        if let mag = dockDefaults?.object(forKey: "magnification") as? NSNumber {
            magnification = mag.boolValue
        } else {
            magnification = false
        }

        // Effective tile size
        let effectiveTile: CGFloat
        if magnification {
            effectiveTile = max(tileSize, floor(largeSize * 0.82))
        } else {
            effectiveTile = tileSize
        }

        let scale: CGFloat = 1.5

        let barHeight = max(36, floor(effectiveTile * 0.80 * scale))
        let iconSize = max(22, floor(effectiveTile * 0.52 * scale))
        let hoverIconSize = max(26, floor(effectiveTile * 0.60 * scale))
        let badgeHeight = max(28, floor(effectiveTile * 0.58 * scale))
        let badgeChipHeight = max(17, floor(effectiveTile * 0.36 * scale))
        let yOffset = max(4, floor((tileSize - barHeight) / 2))
        // Match macOS Dock corner radius (~10pt)
        let cornerRadius = floor(barHeight * 0.16)

        return DockMetrics(
            barHeight: barHeight,
            iconSize: iconSize,
            hoverIconSize: hoverIconSize,
            badgeHeight: badgeHeight,
            badgeChipHeight: badgeChipHeight,
            yOffset: yOffset,
            cornerRadius: cornerRadius
        )
    }
}
