import AppKit
import SwiftUI
import Combine

final class SpacePanelController {
    private var panel: SpacePanel?
    private var hostingView: NSHostingView<SpaceBarView>?
    private let spaceEngine: SpaceEngine
    private let autoHideManager: AutoHideManager
    private let configManager: ConfigManager
    private let pageState = SpaceBarPageState()
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var lastSpaceID: UInt64? = nil
    private var hideWorkItem: DispatchWorkItem?
    private var hotZoneView: HotZoneView?

    deinit {
        if let screenObserver = screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    init(spaceEngine: SpaceEngine, autoHideManager: AutoHideManager) {
        self.spaceEngine = spaceEngine
        self.autoHideManager = autoHideManager
        self.configManager = spaceEngine.configManager
        DispatchQueue.main.async { [weak self] in
            self?.setupPanel()
            self?.observeScreenChanges()
            self?.observeEngine()
            self?.observeAutoHide()
            self?.observeIconsPerPage()
        }
    }

    private func setupPanel(retryCount: Int = 0) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            guard retryCount < 10 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.setupPanel(retryCount: retryCount + 1)
            }
            return
        }
        let screenFrame = screen.frame

        let snapshot = spaceEngine.snapshot
        let initialView = makeSpaceBarView(from: snapshot)
        let hostingView = NSHostingView(rootView: initialView)
        hostingView.frame = screenFrame
        hostingView.autoresizingMask = [.width, .height]
        self.hostingView = hostingView

        let panel = SpacePanel(
            contentRect: screenFrame,
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        let container = NSView(frame: screenFrame)
        container.autoresizingMask = [.width, .height]

        hostingView.frame = screenFrame
        container.addSubview(hostingView)

        let hotZoneView = HotZoneView(frame: CGRect(x: 0, y: 0, width: hotZoneWidth(), height: 61))
        hotZoneView.onMouseEntered = { [weak self] in
            self?.handleMouseEnteredHotZone()
        }
        hotZoneView.onMouseExited = { [weak self] in
            self?.handleMouseExitedHotZone()
        }
        container.addSubview(hotZoneView)
        self.hotZoneView = hotZoneView

        panel.contentView = container
        panel.orderFrontRegardless()

        self.panel = panel
    }

    // MARK: - Mouse Handlers

    private func handleMouseEnteredHotZone() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        if autoHideManager.isEnabled && !autoHideManager.isBarVisible {
            autoHideManager.showBar()
            updateBarView()
        }
    }

    private func handleMouseExitedHotZone() {
        guard autoHideManager.isEnabled && autoHideManager.isBarVisible else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.autoHideManager.hideBar()
            self.updateBarView()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    // MARK: - AutoHide Observer

    private func observeAutoHide() {
        autoHideManager.$isEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self = self else { return }
                if !enabled {
                    self.hideWorkItem?.cancel()
                    self.hideWorkItem = nil
                }
                self.updateBarView()
            }
            .store(in: &cancellables)

        autoHideManager.$isBarVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateBarView()
            }
            .store(in: &cancellables)
    }

    // MARK: - Icons per Page Observer

    private func observeIconsPerPage() {
        configManager.$iconsPerPage
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateBarView()
                self.hotZoneView?.frame.size.width = self.hotZoneWidth()
                // Recompute page for focused app with new grouping
                let snapshot = self.spaceEngine.snapshot
                if let focusedBundleID = snapshot.focusedBundleID,
                   let focusedIndex = snapshot.items.firstIndex(where: { $0.id == focusedBundleID }) {
                    let targetPage = focusedIndex / self.configManager.iconsPerPage
                    if targetPage != self.pageState.currentPage {
                        self.pageState.goToPage(targetPage)
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Engine Observer

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
                    let targetPage = focusedIndex / self.configManager.iconsPerPage
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
            guard let self = self, let panel = self.panel else { return }
            let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
            guard let screen else { return }
            panel.setFrame(screen.frame, display: true)
        }
    }

    // MARK: - View Helpers

    private func hotZoneWidth() -> CGFloat {
        let count = CGFloat(configManager.iconsPerPage)
        let iconStrip = count * SpaceBarConstants.iconSize + (count - 1) * SpaceBarConstants.iconSpacing
        // icon strip + left sections (space number, label, separator) + padding
        return iconStrip + SpaceBarConstants.spaceNumberWidth + SpaceBarConstants.labelWidth
            + SpaceBarConstants.separatorWidth + SpaceBarConstants.sectionSpacing * 3
            + SpaceBarConstants.horizontalPadding * 2 + SpaceBarConstants.leftPadding
    }

    private func updateBarView() {
        guard let hostingView = self.hostingView else { return }
        hostingView.rootView = makeSpaceBarView(from: spaceEngine.snapshot)
    }

    private func makeSpaceBarView(from snapshot: DockSnapshot) -> SpaceBarView {
        SpaceBarView(
            spaceNumber: "\(snapshot.spaceNumber)",
            spaceLabel: snapshot.spaceLabel,
            items: snapshot.items,
            totalItemCount: snapshot.items.count,
            isBarVisible: !autoHideManager.isEnabled || autoHideManager.isBarVisible,
            onEditLabel: { [weak self] in
                self?.promptForSpaceLabelEdit(snapshot: snapshot)
            },
            iconsPerPage: configManager.iconsPerPage,
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

// MARK: - HotZoneView

private final class HotZoneView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
}
