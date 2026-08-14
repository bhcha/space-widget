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
    private var screenRebuildWorkItem: DispatchWorkItem?
    private var displaySetChangedSinceRebuild = false
    private var globalClickMonitor: Any?

    deinit {
        screenRebuildWorkItem?.cancel()
        if let globalClickMonitor = globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
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
            self?.installClickDiagnostics()
        }
    }

    // MARK: - Click Diagnostics
    //
    // After an HDMI unplug the bar is visible but clicks fall through until the user switches
    // spaces — even on a freshly created panel. A global monitor only fires for events delivered
    // to OTHER apps, so a click on the bar that triggers it proves the window server routed the
    // click elsewhere; the CGWindowList dump shows who actually got it.

    private func installClickDiagnostics() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.diagnoseGlobalClick(at: NSEvent.mouseLocation)
        }
        swLog("CLICKDIAG", "global click monitor installed=\(globalClickMonitor != nil)")
    }

    private func diagnoseGlobalClick(at cocoaPoint: NSPoint) {
        for (displayID, context) in panelContexts {
            let frame = context.panel.frame
            // Only care about clicks in the bar strip at the bottom of a panel's screen
            guard frame.contains(cocoaPoint),
                  cocoaPoint.y - frame.minY <= SpaceBarConstants.bottomPadding + SpaceBarConstants.barHeight + 10 else { continue }
            logPanelSpaces(context, reason: "missedClick")
            dumpWindowStack(at: cocoaPoint, panel: context.panel, displayID: displayID)
        }
    }

    /// Log the window-server z-order at a click point, front-to-back, down to our panel.
    private func dumpWindowStack(at cocoaPoint: NSPoint, panel: SpacePanel, displayID: String) {
        // CGWindowList uses top-left-origin global coordinates; Cocoa uses bottom-left.
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let cgPoint = CGPoint(x: cocoaPoint.x, y: primaryHeight - cocoaPoint.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            swLog("CLICKDIAG", "CGWindowListCopyWindowInfo returned nil")
            return
        }
        var lines: [String] = []
        var foundPanel = false
        for info in list {  // already ordered front-to-back
            guard let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard rect.contains(cgPoint) else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let num = info[kCGWindowNumber as String] as? Int ?? 0
            let alpha = info[kCGWindowAlpha as String] as? Double ?? -1
            lines.append("win=\(num) owner=\(owner) layer=\(layer) alpha=\(alpha) bounds=\(rect)")
            if num == panel.windowNumber { foundPanel = true; break }
        }
        swLog("CLICKDIAG", "missed click display=\(displayID) cocoa=\(cocoaPoint) cg=\(cgPoint) panelWin=\(panel.windowNumber) panelInStack=\(foundPanel) stack(front→back):\n  " + lines.joined(separator: "\n  "))
    }

    /// Log which CGS spaces the panel window belongs to vs. the display's current space.
    private func logPanelSpaces(_ context: PanelContext, reason: String) {
        let cid = CGSMainConnectionID()
        // CGSCopySpacesForWindows expects UInt32-tagged NSNumbers; an Int64-tagged box returns [].
        let wid = CGWindowID(context.panel.windowNumber)
        let spaces = CGSCopySpacesForWindows(cid, 0x7, [wid] as CFArray) as? [UInt64] ?? []
        let current = CGSManagedDisplayGetCurrentSpace(cid, context.displayIdentifier as CFString)
        swLog("CLICKDIAG", "\(reason) displayID=\(context.displayIdentifier) panelWin=\(wid) panelSpaces=\(spaces) currentSpace=\(current) onActiveSpace=\(context.panel.isOnActiveSpace) visible=\(context.panel.isVisible)")
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

        logPanelSpaces(context, reason: "panelCreated")
        // Space tagging can lag window creation; sample again after the window server settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let ctx = self.panelContexts[displayID], ctx.panel === context.panel else { return }
            self.logPanelSpaces(ctx, reason: "panelCreated+1s")
        }
    }

    private func removePanelContext(for displayID: String) {
        swLog("PANEL", "removePanelContext displayID=\(displayID)")
        guard let context = panelContexts[displayID] else { return }
        // close() rather than orderOut() so the window leaves NSApp's window list — panels are
        // rebuilt on every display reconfiguration and ordered-out ones would pile up.
        context.panel.close()
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

    private func showDesktopListForDisplay(displayID: String) {
        let allSpaceLists = spaceEngine.spaceMonitor.resolveAllSpaceLists()
        guard let spaceList = allSpaceLists[displayID], !spaceList.isEmpty else {
            swLog("PANEL", "showDesktopList no spaces found for displayID=\(displayID)")
            return
        }

        let mainDisplayID = spaceEngine.spaceMonitor.mainDisplayIdentifier
        let currentSpaceID = spaceEngine.spaceMonitor.displaySpaces[displayID]?.id ?? 0

        let items: [DesktopListItem] = spaceList.map { entry in
            let sid = entry.spaceID
            let ord = entry.ordinal
            let entryUUID = entry.uuid
            let label = configManager.labelFor(
                displayID: displayID,
                spaceID: sid,
                ordinal: ord,
                uuid: entryUUID,
                mainDisplayID: mainDisplayID
            ) ?? ""
            let isCurrent = (sid == currentSpaceID)
            return DesktopListItem(id: sid, ordinal: ord, label: label, isCurrent: isCurrent)
        }

        guard let context = panelContexts[displayID] else { return }
        let panel = context.panel
        let anchorWindowX = SpaceBarConstants.leftPadding
            + SpaceBarConstants.horizontalPadding
            + SpaceBarConstants.spaceNumberWidth / 2
        let anchorWindowY = SpaceBarConstants.bottomPadding + SpaceBarConstants.barHeight
        let anchorWindowPoint = NSPoint(x: anchorWindowX, y: anchorWindowY)
        let anchorScreenPoint = panel.convertPoint(toScreen: anchorWindowPoint)

        swLog("PANEL", "showDesktopList displayID=\(displayID) spaces=\(items.count) currentSpaceID=\(currentSpaceID)")
        showDesktopListMenu(displayID: displayID, items: items, currentSpaceID: currentSpaceID, at: anchorScreenPoint)
    }

    private func showDesktopListMenu(
        displayID: String,
        items: [DesktopListItem],
        currentSpaceID: UInt64,
        at screenPoint: NSPoint
    ) {
        balloonPanel?.dismiss()
        let panel = BalloonMenuPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.balloonPanel = panel

        let content = DesktopListMenuContent(
            items: items,
            currentSpaceID: currentSpaceID,
            onSelect: { [weak self, weak panel] item in
                panel?.dismiss()
                self?.balloonPanel = nil
                guard item.spaceID != currentSpaceID else { return }
                SpaceSwitcher.switchTo(
                    spaceID: item.spaceID,
                    ordinal: item.ordinal,
                    displayID: displayID
                )
            }
        )
        panel.show(content: content, anchorScreenPoint: screenPoint)
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

            // Keep ConfigManager's live display set current for labelFor() fallback
            self.configManager.updateLiveDisplays(currentDisplayIDs)

            // Remove contexts for disconnected displays
            let removedDisplayIDs = existingDisplayIDs.subtracting(currentDisplayIDs)
            for displayID in removedDisplayIDs {
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

            // Trigger space/snapshot refresh on any display-set change. Removals matter as much
            // as additions: when a display disconnects, its spaces migrate to a surviving display
            // and that display's current space CHANGES (e.g. 508 → 3) — but macOS posts no
            // activeSpaceDidChange for this. Without a refresh the snapshot keeps the dead
            // spaceID, and icon clicks (activateApp filters windows by spaceID) silently no-op
            // until the user manually switches spaces.
            if hasNewDisplays || !removedDisplayIDs.isEmpty {
                self.spaceEngine.spaceMonitor.refresh()
                self.displaySetChangedSinceRebuild = true
            }

            self.recomputeAllEffectiveIconsPerPage()
            self.scheduleStalePanelRebuild()
        }
    }

    /// Connecting or disconnecting a display re-parents every overlay window. A panel that
    /// survives the change keeps drawing at its new frame, but the window server can keep routing
    /// mouse events by the pre-change geometry — the bar is visible yet clicks fall through to
    /// whatever is underneath, until a space switch re-registers the window. Rebuilding the panel
    /// once the parameter burst settles hands the window server a brand-new window, the same path
    /// a freshly connected display already takes.
    private func scheduleStalePanelRebuild() {
        screenRebuildWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.rebuildStalePanelContexts()
        }
        screenRebuildWorkItem = workItem
        // didChangeScreenParameters arrives as a burst and the early notifications can still
        // report pre-change frames, so wait for the burst to settle before rebuilding.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    private func rebuildStalePanelContexts() {
        screenRebuildWorkItem = nil
        let displaySetChanged = displaySetChangedSinceRebuild
        displaySetChangedSinceRebuild = false

        for screen in NSScreen.screens {
            guard let displayID = displayIdentifier(for: screen) else { continue }
            guard let context = panelContexts[displayID] else { continue }
            let panelFrame = context.panel.frame
            guard displaySetChanged || panelFrame != screen.frame else { continue }
            swLog("PANEL", "rebuild displayID=\(displayID) panelFrame=\(panelFrame) screenFrame=\(screen.frame) displaySetChanged=\(displaySetChanged)")
            removePanelContext(for: displayID)
            addPanelContext(for: screen, displayID: displayID)
        }

        // Re-read current spaces now that the reconfiguration has settled — the refresh fired
        // during the parameter-change burst can still observe mid-migration values.
        if displaySetChanged {
            spaceEngine.spaceMonitor.refresh()
        }

        recomputeAllEffectiveIconsPerPage()
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
            spaceNumber: "\(snapshot.spaceNumber)",
            spaceLabel: snapshot.spaceLabel,
            items: snapshot.items,
            totalItemCount: snapshot.items.count,
            isBarVisible: !autoHideManager.isEnabled || autoHideManager.isBarVisible,
            onEditLabel: { [weak self] in
                self?.promptForSpaceLabelEdit(snapshot: snapshot, displayID: displayID)
            },
            onSelectSpaceNumber: { [weak self] in
                self?.showDesktopListForDisplay(displayID: displayID)
            },
            iconsPerPage: iconsPerPage,
            pageState: pageState,
            spaceID: snapshot.spaceID,
            displayID: displayID
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
            uuid: snapshot.spaceUUID,
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
