import AppKit
import Combine

final class SpaceEngine: ObservableObject {
    @Published private(set) var snapshots: [String: DockSnapshot] = [:]

    var snapshot: DockSnapshot {
        snapshots[spaceMonitor.mainDisplayIdentifier] ?? DockSnapshot(
            space: ActiveSpace(id: 0, ordinal: 1),
            spaceLabel: "Untitled",
            items: [],
            focusedBundleID: nil,
            capturedAt: Date()
        )
    }

    let configManager: ConfigManager
    let spaceMonitor: SpaceMonitor
    private let windowListProvider: WindowListProvider
    private let windowMoveObserver = WindowMoveObserver()
    private var cancellables = Set<AnyCancellable>()
    private var refreshWorkItem: DispatchWorkItem?
    private var followUpWorkItem: DispatchWorkItem?
    private var pendingSpaceCommitWorkItem: DispatchWorkItem?
    private var confirmedSpaces: [String: ActiveSpace] = [:]
    private var previousConfirmedSpaces: [String: ActiveSpace] = [:]
    private var hasInitialSnapshot = false
    private var configEventsEnabled = false
    private let bootstrapConfigDelay: TimeInterval = 0.2

    init(
        configManager: ConfigManager,
        spaceMonitor: SpaceMonitor = SpaceMonitor(),
        windowListProvider: WindowListProvider = WindowListProvider()
    ) {
        self.configManager = configManager
        self.spaceMonitor = spaceMonitor
        self.windowListProvider = windowListProvider

        observeSpaceChanges()
        observeConfigChanges()
        observeWorkspaceNotifications()

        windowMoveObserver.onWindowMoved = { [weak self] in
            self?.scheduleRefresh(reason: "window_moved", delay: 0.0)
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        refreshWorkItem?.cancel()
        followUpWorkItem?.cancel()
        pendingSpaceCommitWorkItem?.cancel()
    }

    // MARK: - Public

    /// Force an immediate refresh (e.g. called externally after config reload).
    func refresh() {
        guard !confirmedSpaces.isEmpty else { return }
        captureSnapshots(reason: "manual_refresh")
    }

    // MARK: - Observations

    private func observeSpaceChanges() {
        spaceMonitor.$displaySpaces
            .receive(on: DispatchQueue.main)
            .sink { [weak self] displaySpaces in
                guard let self = self else { return }
                for (displayID, activeSpace) in displaySpaces {
                    guard activeSpace.id != 0 else {
                        swLog("SPACE", "ignoring bootstrap zero-id event for display=\(displayID) ordinal=\(activeSpace.ordinal)")
                        continue
                    }
                    let label = self.configManager.labelFor(
                        displayID: displayID,
                        spaceID: activeSpace.id,
                        ordinal: activeSpace.ordinal,
                        mainDisplayID: self.spaceMonitor.mainDisplayIdentifier
                    ) ?? "Untitled"
                    swLog("SPACE", "detected display=\(displayID) ordinal=\(activeSpace.ordinal) id=\(activeSpace.id) label=\(label)")
                    let allLists = self.spaceMonitor.resolveAllSpaceLists()
                    self.configManager.rebindAllOrdinals(
                        displayLists: allLists,
                        mainDisplayID: self.spaceMonitor.mainDisplayIdentifier
                    )
                    self.scheduleSpaceCommit(displayID: displayID, activeSpace)
                }
            }
            .store(in: &cancellables)
    }

    private func observeConfigChanges() {
        configManager.$spaceLabelEntries
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                guard self.configEventsEnabled else { return }
                guard !self.confirmedSpaces.isEmpty else { return }
                self.captureSnapshots(reason: "labels_changed")
            }
            .store(in: &cancellables)

        configManager.$ignoredApps
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                guard self.configEventsEnabled else { return }
                self.scheduleRefresh(reason: "ignored_apps_changed", delay: 0.0)
            }
            .store(in: &cancellables)
    }

    private func observeWorkspaceNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appListDidChange),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appListDidChange),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appVisibilityDidChange),
            name: NSWorkspace.didHideApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appVisibilityDidChange),
            name: NSWorkspace.didUnhideApplicationNotification,
            object: nil
        )
    }

    @objc private func activeAppDidChange(_ notification: Notification) {
        let activatedBundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
            .bundleIdentifier

        // Lightweight: just update focusedBundleID in existing snapshots without full fetch
        if !snapshots.isEmpty {
            var updated: [String: DockSnapshot] = [:]
            for (displayID, snapshot) in snapshots {
                updated[displayID] = snapshot.withFocusedBundleID(activatedBundleID)
            }
            snapshots = updated
        }

        // Single trailing refresh to catch any window changes (e.g. app brought window forward)
        followUpWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.scheduleRefresh(reason: "frontmost_app_trailing", delay: 0.0, preferredFocusedBundleID: activatedBundleID)
        }
        followUpWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @objc private func appVisibilityDidChange() {
        scheduleRefresh(reason: "app_visibility_changed", delay: 0.0)
    }

    @objc private func appListDidChange() {
        scheduleRefresh(reason: "workspace_app_list_changed", delay: 0.1)
        followUpWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.scheduleRefresh(reason: "workspace_app_list_changed_followup", delay: 0.0)
        }
        followUpWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Refresh Scheduling

    private func scheduleRefresh(
        reason: String,
        delay: TimeInterval,
        preferredFocusedBundleID: String? = nil
    ) {
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard !self.confirmedSpaces.isEmpty else { return }
            self.captureSnapshots(reason: reason, preferredFocusedBundleID: preferredFocusedBundleID)
        }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleSpaceCommit(displayID: String, _ candidate: ActiveSpace) {
        // First ever space for this display — commit immediately
        guard let confirmed = confirmedSpaces[displayID] else {
            confirmedSpaces[displayID] = candidate
            captureSnapshots(reason: "space_changed")
            return
        }

        // Same as current confirmed — no-op
        if candidate == confirmed {
            swLog("SPACE", "suppressed transient change; staying on display=\(displayID) ordinal=\(candidate.ordinal) id=\(candidate.id)")
            return
        }

        // Returning to previous confirmed space — instant commit (round-trip recovery)
        if let prev = previousConfirmedSpaces[displayID], candidate == prev {
            swLog("SPACE", "round-trip return to display=\(displayID) ordinal=\(candidate.ordinal) id=\(candidate.id) — instant commit")
            previousConfirmedSpaces[displayID] = confirmed
            confirmedSpaces[displayID] = candidate
            captureSnapshots(reason: "space_changed")
            return
        }

        previousConfirmedSpaces[displayID] = confirmedSpaces[displayID]
        confirmedSpaces[displayID] = candidate
        captureSnapshots(reason: "space_changed")
    }

    // MARK: - Snapshot Capture

    /// Captures snapshots for all known displays. Must be called on the main thread.
    private func captureSnapshots(
        reason: String,
        preferredFocusedBundleID: String? = nil
    ) {
        assert(Thread.isMainThread, "captureSnapshots must be called on main thread")

        let focusedBundleID = preferredFocusedBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let ignoredApps = configManager.ignoredApps
        let spaceLabelEntries = configManager.spaceLabelEntries
        let mainDisplayID = spaceMonitor.mainDisplayIdentifier
        let confirmedSpacesCopy = confirmedSpaces

        swLog("FETCH", "started reason=\(reason) displays=\(confirmedSpacesCopy.count) focusedBundleID=\(focusedBundleID ?? "nil")")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Build display list
            let displayList: [(displayID: String, screenFrame: CGRect, spaceID: UInt64)] = confirmedSpacesCopy.compactMap { displayID, activeSpace in
                guard let screen = NSScreen.screens.first(where: { displayIdentifier(for: $0) == displayID }) else { return nil }
                return (displayID: displayID, screenFrame: screen.frame, spaceID: activeSpace.id)
            }

            // Single CGWindowListCopyWindowInfo call for all displays
            let itemsByDisplay = self.windowListProvider.fetchItemsByDisplay(
                displays: displayList,
                focusedBundleID: focusedBundleID,
                ignoredApps: ignoredApps
            )

            var newSnapshots: [String: DockSnapshot] = [:]

            for (displayID, activeSpace) in confirmedSpacesCopy {
                let candidates = [displayID, displayID == mainDisplayID ? "__main__" : nil].compactMap { $0 }
                let label: String = {
                    if activeSpace.id != 0,
                       let entry = spaceLabelEntries.first(where: { candidates.contains($0.displayID) && $0.spaceID == activeSpace.id }),
                       !entry.label.isEmpty {
                        return entry.label
                    }
                    if let entry = spaceLabelEntries.first(where: { candidates.contains($0.displayID) && $0.ordinal == activeSpace.ordinal && $0.spaceID == 0 }),
                       !entry.label.isEmpty {
                        return entry.label
                    }
                    return "Untitled"
                }()

                let items = itemsByDisplay[displayID] ?? self.windowListProvider.fetchItems(
                    focusedBundleID: focusedBundleID,
                    ignoredApps: ignoredApps
                )

                let names = items.map(\.name)
                swLog("FETCH", "result reason=\(reason) display=\(displayID) ordinal=\(activeSpace.ordinal) count=\(names.count) apps=[\(names.joined(separator: ", "))]")

                newSnapshots[displayID] = DockSnapshot(
                    space: activeSpace,
                    spaceLabel: label,
                    items: items,
                    focusedBundleID: focusedBundleID,
                    capturedAt: Date()
                )
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                // Validate that confirmed spaces still match what we captured
                var valid = true
                for (displayID, activeSpace) in confirmedSpacesCopy {
                    let current = self.confirmedSpaces[displayID] ?? self.spaceMonitor.displaySpaces[displayID]
                    if let current = current, activeSpace != current {
                        swLog("SNAPSHOT", "dropped stale reason=\(reason) display=\(displayID) ordinal=\(activeSpace.ordinal) id=\(activeSpace.id); current ordinal=\(current.ordinal) id=\(current.id)")
                        valid = false
                        break
                    }
                }
                guard valid else { return }

                // Semantic dedup: skip publish if content unchanged
                if newSnapshots != self.snapshots {
                    self.snapshots = newSnapshots
                }
                if !self.hasInitialSnapshot {
                    self.hasInitialSnapshot = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.bootstrapConfigDelay) { [weak self] in
                        self?.configEventsEnabled = true
                    }
                }
                swLog("SNAPSHOT", "applied reason=\(reason) displays=\(newSnapshots.count)")
            }
        }
    }
}
