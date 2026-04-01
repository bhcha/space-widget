import SwiftUI

struct DockBarView: View {
    static let numberWidth: CGFloat = 30
    static let contextWidth: CGFloat = 120
    static let iconSize: CGFloat = 12
    static let iconSpacing: CGFloat = 6
    static let iconsHorizontalPadding: CGFloat = 8
    static let iconsMinWidth: CGFloat = 72
    static let horizontalPadding: CGFloat = 10
    static let interSectionSpacing: CGFloat = 8

    let numberText: String
    let contextText: String
    let items: [DockItem]
    let metrics: DockMetrics

    static func iconsWidth(iconCount: Int) -> CGFloat {
        let clampedCount = max(iconCount, 1)
        let contentWidth =
            CGFloat(clampedCount) * iconSize +
            CGFloat(max(clampedCount - 1, 0)) * iconSpacing
        return max(iconsMinWidth, contentWidth + iconsHorizontalPadding * 2)
    }

    static func panelWidth(iconCount: Int) -> CGFloat {
        numberWidth +
        contextWidth +
        iconsWidth(iconCount: iconCount) +
        horizontalPadding * 2 +
        interSectionSpacing * 2
    }

    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: Self.interSectionSpacing) {
            numberSection
            contextSection
            iconsSection
        }
        .padding(.horizontal, Self.horizontalPadding)
        .frame(height: metrics.barHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(barShape.fill(Theme.barBg))
        .clipShape(barShape)
        .compositingGroup()
    }

    private var numberSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.chipBg)
            Text(numberText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.highlight)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minWidth: Self.numberWidth, maxWidth: Self.numberWidth)
        .frame(height: metrics.barHeight * 0.58)
    }

    private var contextSection: some View {
        HStack(spacing: 0) {
            Text(contextText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(Theme.spaceLabel)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(minWidth: Self.contextWidth, maxWidth: Self.contextWidth, alignment: .leading)
        .frame(height: metrics.barHeight * 0.58)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.bg1.opacity(0.72))
        )
    }

    private var iconsSection: some View {
        HStack(spacing: 6) {
            ForEach(Array(items.prefix(10).enumerated()), id: \.element.id) { index, item in
                Image(nsImage: item.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Self.iconSize, height: Self.iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(item.isFocused ? Theme.highlight : Theme.clusterBorder, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, Self.iconsHorizontalPadding)
        .frame(minWidth: Self.iconsWidth(iconCount: items.prefix(10).count), maxWidth: Self.iconsWidth(iconCount: items.prefix(10).count), alignment: .leading)
        .frame(height: metrics.barHeight * 0.58)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.bg1.opacity(0.56))
        )
    }
}
