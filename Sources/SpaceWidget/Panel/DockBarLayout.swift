import AppKit

enum DockDisplayPhase: Equatable {
    case loading(width: CGFloat)
    case content
}

enum DockBarLayout {
    static let minimumWidth: CGFloat = 96
    private static let dividerWidth: CGFloat = 1
    private static let rootHorizontalPadding: CGFloat = 12
    private static let rootSpacing: CGFloat = 8
    private static let chipWidth: CGFloat = 26
    private static let labelMaxWidth: CGFloat = 160
    private static let loadingSpacing: CGFloat = 10
    private static let loadingHorizontalPadding: CGFloat = 28
    private static let loadingProgressWidth: CGFloat = 96

    static func panelWidth(
        phase: DockDisplayPhase,
        lockedWidth: CGFloat?,
        spaceNumber: Int,
        spaceLabel: String,
        appCount: Int,
        metrics: DockMetrics
    ) -> CGFloat {
        if let lockedWidth {
            return max(lockedWidth, minimumWidth)
        }
        switch phase {
        case .loading(let width):
            return max(width, minimumWidth)
        case .content:
            return max(contentWidth(spaceNumber: spaceNumber, spaceLabel: spaceLabel, appCount: appCount, metrics: metrics), minimumWidth)
        }
    }

    static func cachedWidthForLoading(
        cachedSpaceWidth: CGFloat?,
        lastKnownPanelWidth: CGFloat
    ) -> CGFloat {
        max(cachedSpaceWidth ?? lastKnownPanelWidth, minimumWidth)
    }

    private static func contentWidth(
        spaceNumber: Int,
        spaceLabel: String,
        appCount: Int,
        metrics: DockMetrics
    ) -> CGFloat {
        let badge = badgeWidth()
        let label = labelWidth(spaceLabel: spaceLabel)
        let count = appCountWidth(appCount: appCount)
        return
            rootHorizontalPadding +
            badge +
            rootSpacing +
            label +
            rootSpacing +
            dividerWidth +
            rootSpacing +
            count +
            rootHorizontalPadding
    }

    private static func badgeWidth() -> CGFloat {
        chipWidth
    }

    private static func labelWidth(spaceLabel: String) -> CGFloat {
        let labelFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        let labelText = spaceLabel as NSString
        let measured = ceil(labelText.size(withAttributes: [.font: labelFont]).width)
        return min(measured, labelMaxWidth)
    }

    private static func appCountWidth(appCount: Int) -> CGFloat {
        let countFont = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        let countText = "\(appCount) apps" as NSString
        return ceil(countText.size(withAttributes: [.font: countFont]).width)
    }

    static func loadingBarWidth() -> CGFloat {
        let loadingFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let loadingText = "Loading" as NSString
        let textWidth = ceil(loadingText.size(withAttributes: [.font: loadingFont]).width)
        return max(minimumWidth, loadingHorizontalPadding + textWidth + loadingSpacing + loadingProgressWidth)
    }
}
