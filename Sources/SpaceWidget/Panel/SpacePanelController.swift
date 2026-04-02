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
        let initialView = makeSpaceBarView(from: snapshot)
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
                if snapshot.spaceID != self.lastSpaceID {
                    self.pageState.reset()
                    self.lastSpaceID = snapshot.spaceID
                }
                hostingView.rootView = self.makeSpaceBarView(from: snapshot)

                // Auto-navigate to the page containing the focused app
                if let focusedBundleID = snapshot.focusedBundleID,
                   let focusedIndex = snapshot.items.firstIndex(where: { $0.id == focusedBundleID }) {
                    let targetPage = focusedIndex / SpaceBarConstants.iconsPerPage
                    if targetPage != self.pageState.currentPage {
                        self.pageState.goToPage(targetPage)
                    }
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

    private func makeSpaceBarView(from snapshot: DockSnapshot) -> SpaceBarView {
        SpaceBarView(
            spaceNumber: "\(snapshot.spaceNumber)",
            spaceLabel: snapshot.spaceLabel,
            items: snapshot.items,
            totalItemCount: snapshot.items.count,
            onEditLabel: { [weak self] in
                self?.promptForSpaceLabelEdit(snapshot: snapshot)
            },
            pageState: pageState
        )
    }

    private func promptForSpaceLabelEdit(snapshot: DockSnapshot) {
        let alert = NSAlert()
        alert.messageText = "Edit Space Label"
        alert.informativeText = "Update the context text for Space \(snapshot.spaceNumber)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = snapshot.spaceLabel == "Untitled" ? "" : snapshot.spaceLabel
        alert.accessoryView = textField

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        spaceEngine.configManager.updateSpaceLabel(
            ordinal: snapshot.spaceNumber,
            label: textField.stringValue
        )
    }
}
