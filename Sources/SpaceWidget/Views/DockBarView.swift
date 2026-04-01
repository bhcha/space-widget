import SwiftUI

struct DockBarView: View {
    static let numberWidth: CGFloat = 38
    static let contextWidth: CGFloat = 72
    static let iconSize: CGFloat = 34
    static let perIconHorizontalPadding: CGFloat = 5
    static let iconsHorizontalPadding: CGFloat = 4
    static let iconsMinWidth: CGFloat = 72
    static let horizontalPadding: CGFloat = 10
    static let interSectionSpacing: CGFloat = 8
    static let dividerWidth: CGFloat = 1

    let numberText: String
    let contextText: String
    let items: [DockItem]
    let metrics: DockMetrics

    static func iconsWidth(iconCount: Int) -> CGFloat {
        let clampedCount = max(iconCount, 1)
        let contentWidth =
            CGFloat(clampedCount) * (iconSize + perIconHorizontalPadding * 2)
        return max(iconsMinWidth, contentWidth + iconsHorizontalPadding * 2)
    }

    static func panelWidth(iconCount: Int) -> CGFloat {
        numberWidth +
        contextWidth +
        iconsWidth(iconCount: iconCount) +
        horizontalPadding * 2 +
        interSectionSpacing * 2 +
        dividerWidth
    }

    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: max(metrics.cornerRadius, 10), style: .continuous)
    }

    private var iconCornerRadius: CGFloat {
        max(5, floor(Self.iconSize * 0.22))
    }

    private var numberSectionHeight: CGFloat {
        metrics.barHeight - 14
    }

    private var contextSectionHeight: CGFloat {
        metrics.barHeight - 16
    }

    private var iconsSectionHeight: CGFloat {
        metrics.barHeight - 6
    }

    var body: some View {
        HStack(spacing: Self.interSectionSpacing) {
            numberSection
            contextSection
            divider
            iconsSection
        }
        .padding(.horizontal, Self.horizontalPadding)
        .frame(height: metrics.barHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            barShape
                .fill(Theme.clusterBg)
                .overlay(
                    barShape
                        .strokeBorder(Theme.clusterBorder, lineWidth: 1)
                )
        )
    }

    private var numberSection: some View {
        HStack(spacing: 0) {
            Text(numberText)
                .font(.system(size: 11, weight: .semibold, design: .default))
                .foregroundColor(Theme.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.chipBg)
                )
        }
        .frame(minWidth: Self.numberWidth, maxWidth: Self.numberWidth)
        .frame(height: numberSectionHeight)
    }

    private var contextSection: some View {
        HStack(spacing: 0) {
            Text(contextText)
                .font(.system(size: 10.5, weight: .medium, design: .default))
                .foregroundColor(Theme.spaceLabel)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: Self.contextWidth, maxWidth: Self.contextWidth, alignment: .leading)
        .frame(height: contextSectionHeight)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.clusterBorder)
            .frame(width: Self.dividerWidth)
            .padding(.vertical, 6)
    }

    private var iconsSection: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.prefix(10).enumerated()), id: \.element.id) { index, item in
                Image(nsImage: item.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.iconSize * 0.88, height: Self.iconSize * 0.88)
                    .frame(width: Self.iconSize, height: Self.iconSize)
                    .background(
                        RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous)
                            .fill(item.isFocused ? Theme.highlight.opacity(0.15) : Color.clear)
                    )
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
            }
        }
        .padding(.horizontal, 4)
        .frame(minWidth: Self.iconsWidth(iconCount: items.prefix(10).count), maxWidth: Self.iconsWidth(iconCount: items.prefix(10).count), alignment: .leading)
        .frame(height: iconsSectionHeight)
    }
}
