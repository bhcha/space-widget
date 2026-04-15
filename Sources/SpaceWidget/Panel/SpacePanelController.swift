import AppKit
import SwiftUI
import Combine

final class SpacePanelController {
    private struct PanelContext {
        let displayIdentifier: String
        let panel: SpacePanel
        let hostingView: NSHostingView<SpaceBarView>
        let hotZoneView: HotZoneView
        let pageState: SpaceBarPageState
        var lastSpaceID: UInt64? = nil
        var currentEffectiveIconsPerPage: Int = 5
    }

    private var panelContexts: [String: PanelContext] = [:]
    private var balloonPanel: BalloonMenuPanel?
    private let spaceEngine: SpaceEngine
    private let autoHideManager: AutoHideManager
    private let configManager: ConfigManager
    private let dockGeometry: DockGeometryObserver
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var hideWorkItem: DispatchWorkItem?

    deinit {
        if let screenObserver = screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    init(spaceEngine: SpaceEngine, autoHideManager: AutoHideManager, dockGeometry: DockGeometryObserver) {
        self.spaceEngine = spaceEngine
        self.autoHideManager = autoHideManager
        self.configManager = spaceEngine.configManager
        self.dockGeometry = dockGeometry
        DispatchQueue.main.async { [weak self] in
            self?.setupPanels()
            self?.observeScreenChanges()
            self?.observeEngine()
            self?.observeAutoHide()
            self?.observeLayoutInputs()
        }
    }

    private func setupPanels(retryCount: Int = 0) {
        guard !NSScreen.screens.isEmpty else {
            guard retryCount < 10 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.setupPanels(retryCount: retryCount + 1)
            }
            return
        }

        swLog("PANEL", "setupPanels screens=\(NSScreen.screens.count)")
        for screen in NSScreen.screens {
            let displayID = displayIdentifier(for: screen)
            swLog("PANEL", "screen frame=\(screen.frame) displayID=\(displayID ?? "nil")")
            guard let displayID else { continue }
            guard panelContexts[displayID] == nil else { continue }
            addPanelContext(for: screen, displayID: displayID)
        }
    }

    private func addPanelContext(for screen: NSScreen, displayID: String) {
        swLog("PANEL", "addPanelContext displayID=\(displayID) frame=\(screen.frame)")
        let screenFrame = screen.frame
        let localBounds = CGRect(origin: .zero, size: screenFrame.size)
        let pageState = SpaceBarPageState()

        let initialEffectiveIcons = effectiveIconsPerPage(for: displayID, screen: screen)

        let snapshot = spaceEngine.snapshots[displayID] ?? spaceEngine.snapshot
        let initialView = makeSpaceBarView(from: snapshot, displayID: displayID, pageState: pageState, iconsPerPage: initialEffectiveIcons)
        let hostingView = NSHostingView(rootView: initialView)
        hostingView.frame = localBounds
        hostingView.autoresizingMask = [.width, .height]

        let panel = SpacePanel(
            contentRect: screenFrame,
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        let container = NSView(frame: localBounds)
        container.autoresizingMask = [.width, .height]

        hostingView.frame = localBounds
        container.addSubview(hostingView)

        let hotZoneView = HotZoneView(frame: CGRect(x: 0, y: 0, width: hotZoneWidth(icons: initialEffectiveIcons), height: 61))
        hotZoneView.onMouseEntered = { [weak self] in
            self?.handleMouseEnteredHotZone()
        }
        hotZoneView.onMouseExited = { [weak self] in
            self?.handleMouseExitedHotZone()
        }
        container.addSubview(hotZoneView)

        panel.contentView = container
        panel.orderFrontRegardless()

        swLog("PANEL", "panel created displayID=\(displayID) frame=\(panel.frame) isVisible=\(panel.isVisible) screen=\(panel.screen?.frame.debugDescription ?? "nil") level=\(panel.level.rawValue)")

        panel.onRightClick = { [weak self] windowPoint in
            self?.handleRightClick(at: windowPoint, displayID: displayID)
        }

        var context = PanelContext(
            displayIdentifier: displayID,
            panel: panel,
            hostingView: hostingView,
            hotZoneView: hotZoneView,
            pageState: pageState
        )
        context.currentEffectiveIconsPerPage = initialEffectiveIcons
        panelContexts[displayID] = context
    }

    private func removePanelContext(for displayID: String) {
        swLog("PANEL", "removePanelContext displayID=\(displayID)")
        guard let context = panelContexts[displayID] else { return }
        context.panel.orderOut(nil)
        panelContexts.removeValue(forKey: displayID)
    }

    // MARK: - Mouse Handlers

    private func handleRightClick(at windowPoint: NSPoint, displayID: String) {
        // Suppress when bar is auto-hidden
        if autoHideManager.isEnabled && !autoHideManager.isBarVisible {
            swLog("PANEL", "rightClick suppressed: bar hidden")
            return
        }

        // Bar occupies bottom of screen
        let barTop = SpaceBarConstants.bottomPadding + SpaceBarConstants.barHeight
        guard windowPoint.y <= barTop && windowPoint.y >= SpaceBarConstants.bottomPadding else {
            swLog("PANEL", "rightClick outside bar: y=\(windowPoint.y) barTop=\(barTop) bottomPad=\(SpaceBarConstants.bottomPadding)")
            return
        }

        // Calculate icon strip start X (mirrors hotZoneWidth layout)
        let iconStripStartX = SpaceBarConstants.leftPadding
            + SpaceBarConstants.horizontalPadding
            + SpaceBarConstants.spaceNumberWidth
            + SpaceBarConstants.sectionSpacing
            + SpaceBarConstants.labelWidth
            + SpaceBarConstants.sectionSpacing
            + SpaceBarConstants.separatorWidth
            + SpaceBarConstants.sectionSpacing

        let clickX = windowPoint.x - iconStripStartX
        guard clickX >= 0 else {
            swLog("PANEL", "rightClick before icons: clickX=\(clickX)")
            return
        }

        let iconSlotWidth = SpaceBarConstants.iconSize + SpaceBarConstants.iconSpacing
        let slotIndex = Int(clickX / iconSlotWidth)

        // Check click is within the icon area (not in spacing after the last icon)
        let posInSlot = clickX - CGFloat(slotIndex) * iconSlotWidth
        guard posInSlot <= SpaceBarConstants.iconSize else {
            swLog("PANEL", "rightClick in spacing: posInSlot=\(posInSlot)")
            return
        }

        let iconsPerPage = panelContexts[displayID]?.currentEffectiveIconsPerPage ?? configManager.iconsPerPage
        guard slotIndex < iconsPerPage else {
            swLog("PANEL", "rightClick slot overflow: slotIndex=\(slotIndex) iconsPerPage=\(iconsPerPage)")
            return
        }

        guard let context = panelContexts[displayID] else {
            swLog("PANEL", "rightClick no context for displayID=\(displayID)")
            return
        }
        let pageState = context.pageState
        let itemIndex = pageState.currentPage * iconsPerPage + slotIndex
        let snapshot = spaceEngine.snapshots[displayID] ?? spaceEngine.snapshot
        guard itemIndex < snapshot.items.count else {
            swLog("PANEL", "rightClick item overflow: itemIndex=\(itemIndex) itemCount=\(snapshot.items.count) displayID=\(displayID)")
            return
        }
        let item = snapshot.items[itemIndex]

        // Calculate icon center screen position for balloon anchor
        let iconCenterX = iconStripStartX + CGFloat(slotIndex) * iconSlotWidth + SpaceBarConstants.iconSize / 2
        let iconTopY = barTop
        let screenPoint = context.panel.convertPoint(toScreen: NSPoint(x: iconCenterX, y: iconTopY))

        swLog("PANEL", "rightClick HIT item=\(item.name) slotIndex=\(slotIndex) screenPoint=\(screenPoint) displayID=\(displayID)")
        showBalloonMenu(for: item, at: screenPoint, spaceID: snapshot.spaceID)
    }

    private func showBalloonMenu(for item: DockItem, at screenPoint: NSPoint, spaceID: UInt64? = nil) {
        balloonPanel?.dismiss()

        let panel = BalloonMenuPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.balloonPanel = panel

        let pid = item.pid
        let canNew = AppActions.canOpenNewWindow(pid: pid)

        let content = BalloonMenuContent(
            itemName: item.name,
            canNewWindow: canNew,
            onNewWindow: { [weak self, weak panel] in
                AppActions.openNewWindow(pid: pid)
                panel?.dismiss()
                self?.balloonPanel = nil
            },
            onCloseFromSpace: { [weak self, weak panel] in
                AppActions.closeWindowsOnCurrentSpace(pid: pid, spaceID: spaceID)
                panel?.dismiss()
                self?.balloonPanel = nil
            },
            onQuit: { [weak self, weak panel] in
                NSRunningApplication(processIdentifier: pid)?.terminate()
                panel?.dismiss()
                self?.balloonPanel = nil
            }
        )
        panel.show(content: content, anchorScreenPoint: screenPoint)
    }

    private func handleMouseEnteredHotZone() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        if autoHideManager.isEnabled && !autoHideManager.isBarVisible {
            autoHideManager.showBar()
            updateAllBarViews()
        }
    }

    private func handleMouseExitedHotZone() {
        guard autoHideManager.isEnabled && autoHideManager.isBarVisible else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.autoHideManager.hideBar()
            self.updateAllBarViews()
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
                self.updateAllBarViews()
            }
            .store(in: &cancellables)

        autoHideManager.$isBarVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateAllBarViews()
            }
            .store(in: &cancellables)
    }

    // MARK: - Layout Inputs Observer

    private func observeLayoutInputs() {
        configManager.$iconsPerPage
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeAllEffectiveIconsPerPage()
            }
            .store(in: &cancellables)

        configManager.$overlapDetection
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeAllEffectiveIconsPerPage()
            }
            .store(in: &cancellables)

        dockGeometry.$current
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeAllEffectiveIconsPerPage()
            }
            .store(in: &cancellables)
    }

    // MARK: - Engine Observer

    private func observeEngine() {
        spaceEngine.$snapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshots in
                guard let self = self else { return }
                self.balloonPanel?.dismiss()
                self.balloonPanel = nil
                for (displayID, snapshot) in snapshots {
                    guard var context = self.panelContexts[displayID] else { continue }
                    if snapshot.spaceID != context.lastSpaceID {
                        context.pageState.reset()
                        context.lastSpaceID = snapshot.spaceID
                    }

                    // Recompute effective icons-per-page for this display (item count may have changed)
                    if let screen = NSScreen.screens.first(where: { displayIdentifier(for: $0) == displayID }) {
                        let newEffective = self.effectiveIconsPerPage(for: displayID, screen: screen)
                        if newEffective != context.currentEffectiveIconsPerPage {
                            context.currentEffectiveIconsPerPage = newEffective
                            context.hotZoneView.frame.size.width = self.hotZoneWidth(icons: newEffective)
                        }
                    }
                    self.panelContexts[displayID] = context

                    context.hostingView.rootView = self.makeSpaceBarView(from: snapshot, displayID: displayID, pageState: context.pageState, iconsPerPage: context.currentEffectiveIconsPerPage)

                    // Auto-navigate to the page containing the focused app
                    if let focusedBundleID = snapshot.focusedBundleID,
                       let focusedIndex = snapshot.items.firstIndex(where: { $0.id == focusedBundleID }) {
                        let targetPage = focusedIndex / max(context.currentEffectiveIconsPerPage, 1)
                        if targetPage != context.pageState.currentPage {
                            context.pageState.goToPage(targetPage)
                        }
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
            guard let self = self else { return }

            let currentScreens = NSScreen.screens
            let currentDisplayIDs = Set(currentScreens.compactMap { displayIdentifier(for: $0) })
            let existingDisplayIDs = Set(self.panelContexts.keys)
            swLog("PANEL", "screenParametersChanged currentDisplayIDs=\(currentDisplayIDs) existingDisplayIDs=\(existingDisplayIDs)")

            // Remove contexts for disconnected displays
            for displayID in existingDisplayIDs.subtracting(currentDisplayIDs) {
                self.removePanelContext(for: displayID)
            }

            // Add contexts for newly connected displays
            var hasNewDisplays = false
            for screen in currentScreens {
                guard let displayID = displayIdentifier(for: screen) else { continue }
                if self.panelContexts[displayID] == nil {
                    self.addPanelContext(for: screen, displayID: displayID)
                    hasNewDisplays = true
                } else {
                    // Resize existing panel to updated screen frame
                    self.panelContexts[displayID]?.panel.setFrame(screen.frame, display: true)
                }
            }

            // Trigger space/snapshot refresh so new displays get their own snapshot
            if hasNewDisplays {
                self.spaceEngine.spaceMonitor.refresh()
            }

            self.recomputeAllEffectiveIconsPerPage()
        }
    }

    // MARK: - View Helpers

    private func hotZoneWidth(icons: Int? = nil) -> CGFloat {
        let count = CGFloat(icons ?? configManager.iconsPerPage)
        let iconStrip = count * SpaceBarConstants.iconSize + (count - 1) * SpaceBarConstants.iconSpacing
        // icon strip + left sections (space number, label, separator) + padding
        return iconStrip + SpaceBarConstants.spaceNumberWidth + SpaceBarConstants.labelWidth
            + SpaceBarConstants.separatorWidth + SpaceBarConstants.sectionSpacing * 3
            + SpaceBarConstants.horizontalPadding * 2 + SpaceBarConstants.leftPadding
    }

    private func updateAllBarViews() {
        balloonPanel?.dismiss()
        for (displayID, context) in panelContexts {
            let snapshot = spaceEngine.snapshots[displayID] ?? spaceEngine.snapshot
            context.hostingView.rootView = makeSpaceBarView(from: snapshot, displayID: displayID, pageState: context.pageState, iconsPerPage: context.currentEffectiveIconsPerPage)
        }
    }

    private func makeSpaceBarView(from snapshot: DockSnapshot, displayID: String, pageState: SpaceBarPageState, iconsPerPage: Int) -> SpaceBarView {
        SpaceBarView(
            spaceNumber: displayID == spaceEngine.spaceMonitor.mainDisplayIdentifier ? "\(snapshot.spaceNumber)" : "-",
            spaceLabel: snapshot.spaceLabel,
            items: snapshot.items,
            totalItemCount: snapshot.items.count,
            isBarVisible: !autoHideManager.isEnabled || autoHideManager.isBarVisible,
            onEditLabel: { [weak self] in
                self?.promptForSpaceLabelEdit(snapshot: snapshot, displayID: displayID)
            },
            iconsPerPage: iconsPerPage,
            pageState: pageState,
            spaceID: snapshot.spaceID
        )
    }

    // MARK: - Overlap Detection

    private func effectiveIconsPerPage(for displayID: String, screen: NSScreen) -> Int {
        let configured = configManager.iconsPerPage
        let od = configManager.overlapDetection
        guard od.enabled,
              let dock = dockGeometry.current,
              dock.isVisible,
              dock.displayID == displayID else {
            return configured
        }
        let floor = min(od.minIcons, configured)
        let snapshot = spaceEngine.snapshots[displayID] ?? spaceEngine.snapshot
        let itemCount = snapshot.items.count
        var n = configured
        while n > floor {
            let pageCount = itemCount <= 0 ? 0 : Int(ceil(Double(itemCount) / Double(n)))
            let rect = computeBarRect(screen: screen, icons: n, pageCount: pageCount)
            if !rect.intersects(dock.frame) { return n }
            n = max(floor, n - od.reduceStep)
            if n == floor { break }
        }
        // Final check at floor — if still overlapping, reduction is futile (e.g. left-side Dock
        // covers bar's anchor). Fall back to configured to avoid a uselessly truncated bar.
        let floorPageCount = itemCount <= 0 ? 0 : Int(ceil(Double(itemCount) / Double(n)))
        let floorRect = computeBarRect(screen: screen, icons: n, pageCount: floorPageCount)
        if !floorRect.intersects(dock.frame) { return n }
        return configured
    }

    private func computeBarRect(screen: NSScreen, icons: Int, pageCount: Int = 0) -> CGRect {
        let count = CGFloat(max(icons, 1))
        let iconStrip = count * SpaceBarConstants.iconSize + (count - 1) * SpaceBarConstants.iconSpacing
        var barWidth = iconStrip
            + SpaceBarConstants.spaceNumberWidth
            + SpaceBarConstants.labelWidth
            + SpaceBarConstants.separatorWidth
            + SpaceBarConstants.sectionSpacing * 3
            + SpaceBarConstants.horizontalPadding * 2
        if pageCount > 1 {
            barWidth += SpaceBarConstants.sectionSpacing
                + CGFloat(pageCount) * SpaceBarConstants.pageDotSize
                + CGFloat(pageCount - 1) * SpaceBarConstants.pageDotSpacing
        }
        // Bar is drawn at .bottomLeading inside a full-screen panel with leftPadding/bottomPadding offsets.
        let screenFrame = screen.frame
        let x = screenFrame.origin.x + SpaceBarConstants.leftPadding
        let y = screenFrame.origin.y + SpaceBarConstants.bottomPadding
        return CGRect(x: x, y: y, width: barWidth, height: SpaceBarConstants.barHeight)
    }

    private func recomputeAllEffectiveIconsPerPage() {
        for (displayID, var ctx) in panelContexts {
            guard let screen = NSScreen.screens.first(where: { displayIdentifier(for: $0) == displayID }) else { continue }
            let newValue = effectiveIconsPerPage(for: displayID, screen: screen)
            if newValue != ctx.currentEffectiveIconsPerPage {
                ctx.currentEffectiveIconsPerPage = newValue
                panelContexts[displayID] = ctx
            }
        }
        updateAllBarViews()
        for (displayID, context) in panelContexts {
            context.hotZoneView.frame.size.width = hotZoneWidth(icons: context.currentEffectiveIconsPerPage)
            let snapshot = spaceEngine.snapshots[displayID] ?? spaceEngine.snapshot
            if let focusedBundleID = snapshot.focusedBundleID,
               let focusedIndex = snapshot.items.firstIndex(where: { $0.id == focusedBundleID }) {
                let targetPage = focusedIndex / max(context.currentEffectiveIconsPerPage, 1)
                if targetPage != context.pageState.currentPage {
                    context.pageState.goToPage(targetPage)
                }
            }
        }
    }

    private func promptForSpaceLabelEdit(snapshot: DockSnapshot, displayID: String) {
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
            displayID: displayID,
            spaceID: snapshot.spaceID,
            ordinal: snapshot.spaceNumber,
            label: textField.stringValue,
            mainDisplayID: spaceEngine.spaceMonitor.mainDisplayIdentifier
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
