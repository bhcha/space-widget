import SwiftUI
import AppKit

enum SpaceBarConstants {
    /// Icons per page (test: 5, production: 10)
    static let iconsPerPage = 5
    static let iconSize: CGFloat = 39
    static let iconSpacing: CGFloat = 9
}

struct SpaceBarView: View {
    let spaceNumber: String
    let spaceLabel: String
    let items: [DockItem]
    let totalItemCount: Int

    private var totalPages: Int {
        totalItemCount <= 0 ? 0 : Int(ceil(Double(totalItemCount) / Double(SpaceBarConstants.iconsPerPage)))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
            barContent
                .animation(.smooth(duration: 0.3), value: items.map(\.id))
                .padding(.leading, 8)
                .padding(.bottom, 6)
        }
        .edgesIgnoringSafeArea(.all)
    }

    private var barContent: some View {
        HStack(spacing: 15) {
            Text(spaceNumber)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 32, alignment: .center)

            Text(spaceLabel)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)
                .frame(width: 74, alignment: .leading)

            if !items.isEmpty {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 1.5, height: 18)
            }

            HStack(spacing: SpaceBarConstants.iconSpacing) {
                ForEach(items) { item in
                    Image(nsImage: item.icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: SpaceBarConstants.iconSize, height: SpaceBarConstants.iconSize)
                        .opacity(item.isFocused ? 1 : 0.7)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            if totalPages > 1 {
                HStack(spacing: 3) {
                    ForEach(0..<totalPages, id: \.self) { page in
                        Circle()
                            .fill(Color.white.opacity(page == 0 ? 0.8 : 0.25))
                            .frame(width: 4, height: 4)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 45)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
    }
}
