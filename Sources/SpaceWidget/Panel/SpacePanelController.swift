import AppKit
import SwiftUI
import Combine

final class SpacePanelController {
    private var panel: SpacePanel?
    private var hostingView: NSHostingView<SpaceBarView>?
    private let spaceEngine: SpaceEngine
    private let pageState = SpaceBarPageState()
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var lastSpaceID: UInt64? = nil

    deinit {
        if let screenObserver = screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    init(spaceEngine: SpaceEngine) {
        self.spaceEngine = spaceEngine
        setupPanel()
        observeScreenChanges()
        observeEngine()
    }

    private func setupPanel() {
        guard let screenFrame = NSScreen.main?.frame else { return }

        let snapshot = spaceEngine.snapshot
        let initialView = SpaceBarView(
            spaceNumber: "\(snapshot.spaceNumber)",
            spaceLabel: snapshot.spaceLabel,
            items: snapshot.items,
            totalItemCount: snapshot.items.count,
            pageState: pageState
        )
        let hostingView = NSHostingView(rootView: initialView)
        self.hostingView = hostingView

        let panel = SpacePanel(
            contentRect: screenFrame,
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.contentView = hostingView
        panel.orderFront(nil)

        self.panel = panel
    }

    private func observeEngine() {
        spaceEngine.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                swLog("NAV", "sink fired reason=snapshot_changed apps=\(snapshot.items.count) focused=\(snapshot.focusedBundleID ?? "nil")")
                guard let self = self, let hostingView = self.hostingView else {
                    swLog("NAV", "sink guard failed self=\(self == nil ? "nil" : "ok") hostingView=\(self?.hostingView == nil ? "nil" : "ok")")
                    return
                }
                if snapshot.spaceID != self.lastSpaceID {
                    self.pageState.reset()
                    self.lastSpaceID = snapshot.spaceID
                }
                hostingView.rootView = SpaceBarView(
                    spaceNumber: "\(snapshot.spaceNumber)",
                    spaceLabel: snapshot.spaceLabel,
                    items: snapshot.items,
                    totalItemCount: snapshot.items.count,
                    pageState: self.pageState
                )

                // Auto-navigate to the page containing the focused app
                let focusedID = snapshot.focusedBundleID ?? "nil"
                let currentPage = self.pageState.currentPage
                if let focusedBundleID = snapshot.focusedBundleID,
                   let focusedIndex = snapshot.items.firstIndex(where: { $0.id == focusedBundleID }) {
                    let targetPage = focusedIndex / SpaceBarConstants.iconsPerPage
                    swLog("NAV", "focusedBundleID=\(focusedID) focusedIndex=\(focusedIndex) targetPage=\(targetPage) currentPage=\(currentPage)")
                    if targetPage != self.pageState.currentPage {
                        self.pageState.goToPage(targetPage)
                    }
                } else {
                    swLog("NAV", "focusedBundleID=\(focusedID) focusedIndex=nil currentPage=\(currentPage)")
                }
            }
            .store(in: &cancellables)
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let panel = self.panel, let screen = panel.screen else { return }
            panel.setFrame(screen.frame, display: true)
        }
    }
}
