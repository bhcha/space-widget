import AppKit
import SwiftUI
import Combine

final class SpacePanelController {
    private var panel: SpacePanel?
    private var hostingView: NSHostingView<SpaceBarView>?
    private let spaceEngine: SpaceEngine
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?

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
            spaceLabel: snapshot.spaceLabel
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
                guard let self = self, let hostingView = self.hostingView else { return }
                hostingView.rootView = SpaceBarView(
                    spaceNumber: "\(snapshot.spaceNumber)",
                    spaceLabel: snapshot.spaceLabel
                )
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
