import SwiftUI
import AppKit

enum SpaceBarConstants {
    /// Icons per page
    static let iconsPerPage = 5
    static let iconSize: CGFloat = 39
    static let iconSpacing: CGFloat = 9
    static let leftPadding: CGFloat = 8
    static let bottomPadding: CGFloat = 6
    static let barHeight: CGFloat = 45
    static let horizontalPadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 15
    static let spaceNumberWidth: CGFloat = 32
    static let labelWidth: CGFloat = 74
    static let separatorWidth: CGFloat = 1.5
    static let pageDotSize: CGFloat = 4
    static let pageDotSpacing: CGFloat = 3
}

final class SpaceBarPageState: ObservableObject {
    @Published var currentPage = 0

    func goToNextPage(totalPages: Int) {
        guard currentPage < totalPages - 1 else { return }
        currentPage += 1
    }

    func goToPreviousPage() {
        guard currentPage > 0 else { return }
        currentPage -= 1
    }

    func goToPage(_ page: Int) {
        currentPage = page
    }

    func reset() {
        currentPage = 0
    }

    func clampPage(totalPages: Int) {
        if totalPages <= 0 { currentPage = 0; return }
        if currentPage >= totalPages { currentPage = totalPages - 1 }
    }
}

struct SpaceBarView: View {
    let spaceNumber: String
    let spaceLabel: String
    let items: [DockItem]
    let totalItemCount: Int
    let isBarVisible: Bool
    let onEditLabel: () -> Void

    @ObservedObject var pageState: SpaceBarPageState
    @GestureState private var dragOffset: CGFloat = 0

    private var currentPage: Int {
        pageState.currentPage
    }

    private var totalPages: Int {
        totalItemCount <= 0 ? 0 : Int(ceil(Double(totalItemCount) / Double(SpaceBarConstants.iconsPerPage)))
    }

    private var iconViewportWidth: CGFloat {
        let count = CGFloat(SpaceBarConstants.iconsPerPage)
        return count * SpaceBarConstants.iconSize + (count - 1) * SpaceBarConstants.iconSpacing
    }

    private var pagedItems: [[DockItem]] {
        stride(from: 0, to: items.count, by: SpaceBarConstants.iconsPerPage).map { start in
            Array(items[start..<min(start + SpaceBarConstants.iconsPerPage, items.count)])
        }
    }

    private var pageStripOffset: CGFloat {
        let baseOffset = -CGFloat(currentPage) * iconViewportWidth
        // Rubber-band at edges
        let isAtStart = currentPage == 0 && dragOffset > 0
        let isAtEnd = currentPage >= totalPages - 1 && dragOffset < 0
        let effectiveDrag = (isAtStart || isAtEnd) ? dragOffset * 0.3 : dragOffset
        return baseOffset + effectiveDrag
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .allowsHitTesting(false)
            interactiveBarContent
                .padding(.leading, SpaceBarConstants.leftPadding)
                .padding(.bottom, SpaceBarConstants.bottomPadding)
                .offset(y: isBarVisible ? 0 : SpaceBarConstants.barHeight + SpaceBarConstants.bottomPadding + 10)
                .animation(.easeInOut(duration: 0.25), value: isBarVisible)
                .allowsHitTesting(isBarVisible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .edgesIgnoringSafeArea(.all)
        .onChange(of: totalPages) { _, newTotal in
            pageState.clampPage(totalPages: newTotal)
        }
    }

    /// Activate a specific window on the current space via AXUIElement,
    /// avoiding NSRunningApplication.activate which can jump to another space.
    private func activateApp(pid: pid_t) {
        forEachWindowOnCurrentSpace(pid: pid) { appElement, axWindow, wid in
            let raiseResult = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            let frontResult = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue as CFTypeRef)
            if raiseResult == .success && frontResult == .success {
                return true // stop — activated successfully
            }
            swLog("ACTIVATE", "AXAction failed pid=\(pid) wid=\(wid) raise=\(raiseResult.rawValue) front=\(frontResult.rawValue), trying next window")
            return false
        }
    }

    /// Close only the windows of an app on the current space.
    /// Windows on other spaces or pinned to all spaces remain open; the app keeps running.
    private func closeWindowsOnCurrentSpace(pid: pid_t) {
        forEachWindowOnCurrentSpace(pid: pid, singleSpaceOnly: true) { _, axWindow, _ in
            var closeButtonRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
                  let closeButtonRef else { return false }
            // swiftlint:disable:next force_cast
            AXUIElementPerformAction(closeButtonRef as! AXUIElement, kAXPressAction as CFString)
            return false // continue — close all matching windows
        }
    }

    private var interactiveBarContent: some View {
        barContent
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 15)
                    .updating($dragOffset) { value, state, transaction in
                        state = value.translation.width
                        transaction.animation = nil // no animation during drag — track finger 1:1
                    }
                    .onEnded { value in
                        let threshold: CGFloat = iconViewportWidth * 0.3
                        let projected = value.predictedEndTranslation.width

                        if projected < -threshold {
                            withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.8)) {
                                pageState.goToNextPage(totalPages: totalPages)
                            }
                        } else if projected > threshold {
                            withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.8)) {
                                pageState.goToPreviousPage()
                            }
                        }
                    }
            )
            .animation(.smooth(duration: 0.3), value: items.map(\.id))
    }

    private var barContent: some View {
        HStack(spacing: SpaceBarConstants.sectionSpacing) {
            Text(spaceNumber)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: SpaceBarConstants.spaceNumberWidth, alignment: .center)

            Button(action: onEditLabel) {
                Text(spaceLabel)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                    .frame(width: SpaceBarConstants.labelWidth, alignment: .leading)
            }
            .buttonStyle(.plain)

            if !pagedItems.isEmpty {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: SpaceBarConstants.separatorWidth, height: 18)
            }

            // Icon strip viewport
            HStack(spacing: 0) {
                ForEach(pagedItems.indices, id: \.self) { pageIndex in
                    HStack(spacing: SpaceBarConstants.iconSpacing) {
                        ForEach(pagedItems[pageIndex]) { item in
                            Image(nsImage: item.icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: SpaceBarConstants.iconSize - 6, height: SpaceBarConstants.iconSize - 6)
                                .padding(3)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(item.isFocused ? Color.white.opacity(0.2) : Color.clear)
                                )
                                .opacity(item.isFocused ? 1 : 0.7)
                                .onTapGesture {
                                    activateApp(pid: item.pid)
                                }
                                .contextMenu {
                                    Button("Close from this Space") {
                                        closeWindowsOnCurrentSpace(pid: item.pid)
                                    }
                                    Divider()
                                    Button("Quit \(item.name)") {
                                        NSRunningApplication(processIdentifier: item.pid)?.terminate()
                                    }
                                }
                        }
                    }
                    .frame(width: iconViewportWidth, alignment: .leading)
                }
            }
            .offset(x: pageStripOffset)
            .frame(width: iconViewportWidth, alignment: .leading)
            .clipped()

            if totalPages > 1 {
                HStack(spacing: 3) {
                    ForEach(0..<totalPages, id: \.self) { page in
                        Circle()
                            .fill(Color.white.opacity(page == currentPage ? 0.8 : 0.25))
                            .frame(width: SpaceBarConstants.pageDotSize, height: SpaceBarConstants.pageDotSize)
                    }
                }
            }
        }
        .padding(.horizontal, SpaceBarConstants.horizontalPadding)
        .frame(height: SpaceBarConstants.barHeight)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
    }
}
