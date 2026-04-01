import AppKit
import SwiftUI
import Combine

final class DockPanelController {
    private let significantWidthJumpThreshold: CGFloat = 80
    private let significantHeightJumpThreshold: CGFloat = 8
    private let maxVisibleIcons = 10

    private let configManager = ConfigManager()
    private let spaceMonitor = SpaceMonitor()
    private let windowListProvider = WindowListProvider()

    private var panel: DockPanel?
    private var hostingView: NSHostingView<DockBarView>?
    private var metrics: DockMetrics
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var dockPrefObserver: NSObjectProtocol?
    private var panelResizeObserver: NSObjectProtocol?
    private var panelMoveObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var currentSpace = ActiveSpace(id: 0, ordinal: 1)
    private var currentItems: [DockItem] = []
    private var appLifecycleObservers: [NSObjectProtocol] = []

    init() {
        self.metrics = DockMetrics.current()
        setupPanel()
        observeSpaceChanges()
        observeSpaceLabels()
        observeWorkspaceAppChanges()
        observeApplicationLifecycle()
        observeScreenChanges()
        observeDockPrefChanges()
    }

    private func setupPanel() {
        let metrics = self.metrics
        let initialWidth = DockBarView.panelWidth(iconCount: 1)
        let size = NSSize(width: initialWidth, height: metrics.barHeight)
        let frame = defaultFrame(contentSize: size)

        swLog(
            "SIZE",
            "setup requested contentSize=\(string(size)) frame=\(string(frame)) metrics(barHeight=\(metrics.barHeight), yOffset=\(metrics.yOffset), iconSize=\(metrics.iconSize))"
        )

        let hosting = NSHostingView(rootView: DockBarView(
            numberText: String(currentSpace.ordinal),
            contextText: currentSpaceLabel,
            items: Array(currentItems.prefix(maxVisibleIcons)),
            metrics: metrics
        ))
        let panel = DockPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        let container = FirstMouseView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.autoresizesSubviews = true

        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        self.panel = panel
        self.hostingView = hosting
        observePanelGeometry(panel)
        logGeometry(context: "setup_applied")
    }

    private func observeSpaceChanges() {
        spaceMonitor.$currentSpace
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] activeSpace in
                guard let self = self else { return }
                guard activeSpace.id != 0 else { return }
                self.currentSpace = activeSpace
                self.refreshPanel(reason: "space_changed")
            }
            .store(in: &cancellables)
    }

    private func observeSpaceLabels() {
        configManager.$spaceLabels
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshPanel(reason: "space_labels_changed")
            }
            .store(in: &cancellables)
    }

    private func observeWorkspaceAppChanges() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.willLaunchApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]

        for name in names {
            let observer = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self = self else { return }
                self.logWorkspaceNotification(name: name, notification: notification)
                self.refreshPanel(reason: "workspace_app_changed:\(name.rawValue)")
            }
            workspaceObservers.append(observer)
        }
    }

    private func observeApplicationLifecycle() {
        let names: [NSNotification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didChangeScreenParametersNotification
        ]

        for name in names {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.logApplicationNotification(name: name, notification: notification)
            }
            appLifecycleObservers.append(observer)
        }
    }

    private func refreshPanel(reason: String) {
        guard let panel = panel, let hosting = hostingView else { return }
        currentItems = windowListProvider.fetchItems(focusedBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        let visibleItems = Array(currentItems.prefix(maxVisibleIcons))
        let appNames = visibleItems.map(\.name).joined(separator: ", ")

        logGeometry(
            context: "update_before",
            extra: "reason=\(reason) space(ordinal=\(currentSpace.ordinal), id=\(currentSpace.id)) apps=\(visibleItems.count) [\(appNames)]"
        )

        hosting.rootView = DockBarView(
            numberText: String(currentSpace.ordinal),
            contextText: currentSpaceLabel,
            items: visibleItems,
            metrics: metrics
        )

        let oldFrame = panel.frame
        var newFrame = oldFrame
        let layoutWidth = DockBarView.panelWidth(iconCount: visibleItems.count)
        let fittingWidth = ceil(hosting.fittingSize.width)
        let layoutWidthText = String(format: "%.1f", layoutWidth)
        let fittingWidthText = String(format: "%.1f", fittingWidth)
        let appliedWidth = max(layoutWidth, fittingWidth)
        newFrame.size.width = appliedWidth
        newFrame.size.height = metrics.barHeight

        swLog(
            "SIZE",
            "update_apply reason=\(reason) space(ordinal=\(currentSpace.ordinal), id=\(currentSpace.id)) apps=\(visibleItems.count) [\(appNames)] layoutWidth=\(layoutWidthText) fittingWidth=\(fittingWidthText) appliedWidth=\(String(format: "%.1f", appliedWidth)) targetFrame=\(string(newFrame)) targetHeight=\(metrics.barHeight)"
        )

        logSignificantSizeJumpIfNeeded(
            oldFrame: oldFrame,
            newFrame: newFrame,
            fittingSize: hosting.fittingSize,
            reason: "reason=\(reason) space(ordinal=\(currentSpace.ordinal), id=\(currentSpace.id)) apps=\(visibleItems.count) [\(appNames)]"
        )

        panel.contentView?.frame = NSRect(origin: .zero, size: newFrame.size)
        hosting.frame = NSRect(origin: .zero, size: newFrame.size)
        panel.setFrame(newFrame, display: true, animate: false)
        logGeometry(context: "update_after")
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            swLog("EVENT", "nsapplication.didChangeScreenParametersNotification observed by DockPanelController")
            swLog("SIZE", "screen_parameters_changed")
            self.metrics = DockMetrics.current()
            self.repositionPanel()
        }
    }

    private func observeDockPrefChanges() {
        dockPrefObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.dock.prefchanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            swLog("EVENT", "distributed.com.apple.dock.prefchanged received")
            swLog("SIZE", "dock_preferences_changed")
            self.metrics = DockMetrics.current()
            self.repositionPanel()
        }
    }

    private func repositionPanel() {
        guard let panel = panel, let hosting = hostingView else { return }
        logGeometry(context: "reposition_before")

        let size = NSSize(width: panel.frame.width, height: metrics.barHeight)
        let frame = defaultFrame(contentSize: size)
        swLog(
            "SIZE",
            "reposition_apply requestedContent=\(string(size)) targetFrame=\(string(frame)) metrics(barHeight=\(metrics.barHeight), yOffset=\(metrics.yOffset), iconSize=\(metrics.iconSize))"
        )

        panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        panel.setFrame(frame, display: true, animate: false)
        logGeometry(context: "reposition_after")
    }

    private func defaultFrame(contentSize: NSSize) -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main

        guard let screen = targetScreen else {
            return NSRect(x: 8, y: 8, width: contentSize.width, height: contentSize.height)
        }

        let padding: CGFloat = 8
        let x = screen.visibleFrame.minX + padding
        let y = screen.visibleFrame.minY + metrics.yOffset
        return NSRect(x: x, y: y, width: contentSize.width, height: metrics.barHeight)
    }

    private var currentSpaceLabel: String {
        configManager.spaceLabels[currentSpace.ordinal] ?? "Untitled"
    }

    private func observePanelGeometry(_ panel: DockPanel) {
        panelResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.logGeometry(context: "panel_did_resize")
        }

        panelMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.logGeometry(context: "panel_did_move")
        }
    }

    private func logGeometry(context: String, extra: String? = nil) {
        guard let panel = panel, let hosting = hostingView else { return }

        let panelFrame = panel.frame
        let contentFrame = panel.contentView?.frame ?? .zero
        let hostingFrame = hosting.frame
        let fittingSize = hosting.fittingSize
        let visibleFrame = panel.screen?.visibleFrame ?? .zero
        var message = "\(context) panel=\(string(panelFrame)) content=\(string(contentFrame)) hosting=\(string(hostingFrame)) fitting=\(string(fittingSize)) visible=\(string(visibleFrame)) metrics(barHeight=\(metrics.barHeight), yOffset=\(metrics.yOffset), iconSize=\(metrics.iconSize))"

        if let extra {
            message += " \(extra)"
        }

        swLog("SIZE", message)
    }

    private func logWorkspaceNotification(name: NSNotification.Name, notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let appName = app?.localizedName ?? "nil"
        let bundleID = app?.bundleIdentifier ?? "nil"
        let pid = app.map { String($0.processIdentifier) } ?? "nil"
        swLog(
            "EVENT",
            "workspace notification=\(name.rawValue) app=\(appName) bundleID=\(bundleID) pid=\(pid)"
        )
    }

    private func logApplicationNotification(name: NSNotification.Name, notification: Notification) {
        swLog("EVENT", "application notification=\(name.rawValue)")
    }

    private func logSignificantSizeJumpIfNeeded(
        oldFrame: NSRect,
        newFrame: NSRect,
        fittingSize: NSSize,
        reason: String
    ) {
        let widthDelta = newFrame.width - oldFrame.width
        let heightDelta = newFrame.height - oldFrame.height
        let absWidthDelta = abs(widthDelta)
        let absHeightDelta = abs(heightDelta)
        guard absWidthDelta >= significantWidthJumpThreshold || absHeightDelta >= significantHeightJumpThreshold else {
            return
        }

        let widthScale = oldFrame.width > 0 ? (newFrame.width / oldFrame.width) : 0
        let heightScale = oldFrame.height > 0 ? (newFrame.height / oldFrame.height) : 0
        swLog(
            "SIZE-JUMP",
            "old=\(string(oldFrame)) new=\(string(newFrame)) delta={\(String(format: "%.1f", widthDelta)), \(String(format: "%.1f", heightDelta))} scale={\(String(format: "%.3f", widthScale)), \(String(format: "%.3f", heightScale))} fitting=\(string(fittingSize)) \(reason)"
        )
    }

    private func string(_ rect: NSRect) -> String {
        NSStringFromRect(rect)
    }

    private func string(_ size: NSSize) -> String {
        NSStringFromSize(size)
    }

    deinit {
        if let obs = screenObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = dockPrefObserver { DistributedNotificationCenter.default().removeObserver(obs) }
        if let obs = panelResizeObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = panelMoveObserver { NotificationCenter.default.removeObserver(obs) }
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        for observer in appLifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
