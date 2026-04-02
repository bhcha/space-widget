import SwiftUI
import AppKit

enum SpaceBarConstants {
    /// Icons per page (test: 5, production: 10)
    static let iconsPerPage = 5
    static let iconSize: CGFloat = 39
    static let iconSpacing: CGFloat = 9
}

enum SpaceBarSwipeDirection {
    case previous
    case next

    var transition: AnyTransition {
        switch self {
        case .previous:
            return .asymmetric(
                insertion: .move(edge: .leading),
                removal: .move(edge: .trailing)
            )
        case .next:
            return .asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            )
        }
    }
}

final class SpaceBarPageState: ObservableObject {
    @Published private(set) var currentPage = 0
    @Published private(set) var swipeDirection: SpaceBarSwipeDirection = .next

    func goToNextPage(totalPages: Int) {
        guard currentPage < totalPages - 1 else { return }
        swipeDirection = .next
        currentPage += 1
    }

    func goToPreviousPage() {
        guard currentPage > 0 else { return }
        swipeDirection = .previous
        currentPage -= 1
    }

    func reset() {
        currentPage = 0
        swipeDirection = .next
    }

    func clampPage(totalPages: Int) {
        let clampedPage = max(0, min(currentPage, totalPages - 1))
        guard clampedPage != currentPage else { return }
        swipeDirection = clampedPage > currentPage ? .next : .previous
        currentPage = clampedPage
    }
}

struct SpaceBarView: View {
    let spaceNumber: String
    let spaceLabel: String
    let items: [DockItem]
    let totalItemCount: Int

    @ObservedObject var pageState: SpaceBarPageState

    private var currentPage: Int {
        pageState.currentPage
    }

    private var totalPages: Int {
        totalItemCount <= 0 ? 0 : Int(ceil(Double(totalItemCount) / Double(SpaceBarConstants.iconsPerPage)))
    }

    private var currentPageItems: [DockItem] {
        let start = currentPage * SpaceBarConstants.iconsPerPage
        let end = min(start + SpaceBarConstants.iconsPerPage, items.count)
        guard start < items.count else { return [] }
        return Array(items[start..<end])
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .allowsHitTesting(false)
            barContent
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 30)
                        .onEnded { value in
                            let horizontal = value.translation.width
                            if horizontal < -30 && currentPage < totalPages - 1 {
                                withAnimation(.smooth(duration: 0.25)) {
                                    pageState.goToNextPage(totalPages: totalPages)
                                }
                            } else if horizontal > 30 && currentPage > 0 {
                                withAnimation(.smooth(duration: 0.25)) {
                                    pageState.goToPreviousPage()
                                }
                            }
                        }
                )
                .animation(.smooth(duration: 0.3), value: items.map(\.id))
                .padding(.leading, 8)
                .padding(.bottom, 6)
        }
        .edgesIgnoringSafeArea(.all)
        .onChange(of: totalPages) { _, newTotal in
            pageState.clampPage(totalPages: newTotal)
        }
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

            if !currentPageItems.isEmpty {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 1.5, height: 18)
            }

            ZStack {
                HStack(spacing: SpaceBarConstants.iconSpacing) {
                    ForEach(currentPageItems) { item in
                        Image(nsImage: item.icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: SpaceBarConstants.iconSize, height: SpaceBarConstants.iconSize)
                            .opacity(item.isFocused ? 1 : 0.7)
                    }
                }
                .id(currentPage)
                .transition(pageState.swipeDirection.transition)
            }
            .clipped()

            if totalPages > 1 {
                HStack(spacing: 3) {
                    ForEach(0..<totalPages, id: \.self) { page in
                        Circle()
                            .fill(Color.white.opacity(page == currentPage ? 0.8 : 0.25))
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
