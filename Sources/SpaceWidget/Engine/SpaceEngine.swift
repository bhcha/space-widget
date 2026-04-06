import AppKit
import Combine

final class SpaceEngine: ObservableObject {
    @Published private(set) var snapshot: DockSnapshot

    let configManager: ConfigManager
    private let spaceMonitor: SpaceMonitor
    private let windowListProvider: WindowListProvider
    private var cancellables = Set<AnyCancellable>()
    private var refreshWorkItem: DispatchWorkItem?
    private var followUpWorkItem: DispatchWorkItem?
    private var pendingSpaceCommitWorkItem: DispatchWorkItem?
    private var confirmedSpace: ActiveSpace?
    private var previousConfirmedSpace: ActiveSpace?
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

        // Bootstrap empty snapshot
        self.snapshot = DockSnapshot(
            space: ActiveSpace(id: 0, ordinal: 1),
            spaceLabel: "Untitled",
            items: [],
            focusedBundleID: nil,
            capturedAt: Date()
        )

        observeSpaceChanges()
        observeConfigChanges()
        observeWorkspaceNotifications()
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
        let activeSpace = confirmedSpace ?? spaceMonitor.currentSpace
        guard activeSpace.id != 0 else { return }
        captureSnapshot(reason: "manual_refresh", activeSpace: activeSpace)
    }

    // MARK: - Observations

    private func observeSpaceChanges() {
        spaceMonitor.$currentSpace
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] activeSpace in
                guard let self = self else { return }
                guard activeSpace.id != 0 else {
                    swLog("SPACE", "ignoring bootstrap zero-id event for ordinal=\(activeSpace.ordinal)")
                    return
                }
                let label = self.configManager.spaceLabels[activeSpace.ordinal] ?? "Untitled"
                swLog("SPACE", "detected ordinal=\(activeSpace.ordinal) id=\(activeSpace.id) label=\(label)")
                self.scheduleSpaceCommit(activeSpace)
            }
            .store(in: &cancellables)
    }

    private func observeConfigChanges() {
        configManager.$spaceLabels
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                guard self.configEventsEnabled else { return }
                let activeSpace = self.confirmedSpace ?? self.spaceMonitor.currentSpace
                guard activeSpace.id != 0 else { return }
                self.captureSnapshot(reason: "labels_changed", activeSpace: activeSpace)
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
        scheduleRefresh(
            reason: "frontmost_app_changed",
            delay: 0.0,
            preferredFocusedBundleID: activatedBundleID
        )

        followUpWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.scheduleRefresh(
                reason: "frontmost_app_changed_followup",
                delay: 0.0,
                preferredFocusedBundleID: activatedBundleID
            )
        }
        followUpWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
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
            let activeSpace = self.confirmedSpace ?? self.spaceMonitor.currentSpace
            guard activeSpace.id != 0 else { return }
            self.captureSnapshot(
                reason: reason,
                activeSpace: activeSpace,
                preferredFocusedBundleID: preferredFocusedBundleID
            )
        }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleSpaceCommit(_ candidate: ActiveSpace) {
        pendingSpaceCommitWorkItem?.cancel()

        // First ever space — commit immediately
        guard let confirmed = confirmedSpace else {
            confirmedSpace = candidate
            captureSnapshot(reason: "space_changed", activeSpace: candidate)
            return
        }

        // Same as current confirmed — no-op (suppresses return during pending)
        if candidate == confirmed {
            swLog("SPACE", "suppressed transient change; staying on ordinal=\(candidate.ordinal) id=\(candidate.id)")
            return
        }

        // Returning to previous confirmed space — instant commit (round-trip recovery)
        if let prev = previousConfirmedSpace, candidate == prev {
            swLog("SPACE", "round-trip return to ordinal=\(candidate.ordinal) id=\(candidate.id) — instant commit")
            previousConfirmedSpace = confirmed
            confirmedSpace = candidate
            captureSnapshot(reason: "space_changed", activeSpace: candidate)
            return
        }

        self.previousConfirmedSpace = self.confirmedSpace
        self.confirmedSpace = candidate
        self.captureSnapshot(reason: "space_changed", activeSpace: candidate)
    }

    // MARK: - Snapshot Capture

    /// Captures a snapshot. Must be called on the main thread so ignoredApps is read safely.
    private func captureSnapshot(
        reason: String,
        activeSpace: ActiveSpace,
        preferredFocusedBundleID: String? = nil
    ) {
        assert(Thread.isMainThread, "captureSnapshot must be called on main thread")

        let label = configManager.spaceLabels[activeSpace.ordinal] ?? "Untitled"
        let focusedBundleID = preferredFocusedBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Capture ignoredApps on main thread to avoid data race
        let ignoredApps = configManager.ignoredApps

        swLog(
            "FETCH",
            "started reason=\(reason) ordinal=\(activeSpace.ordinal) id=\(activeSpace.id) label=\(label) focusedBundleID=\(focusedBundleID ?? "nil")"
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let items = self.windowListProvider.fetchItems(
                focusedBundleID: focusedBundleID,
                ignoredApps: ignoredApps
            )
            let names = items.map(\.name)
            swLog("FETCH", "result reason=\(reason) count=\(names.count) apps=[\(names.joined(separator: ", "))]")

            let newSnapshot = DockSnapshot(
                space: activeSpace,
                spaceLabel: label,
                items: items,
                focusedBundleID: focusedBundleID,
                capturedAt: Date()
            )

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let expectedSpace = self.confirmedSpace ?? self.spaceMonitor.currentSpace
                guard activeSpace == expectedSpace else {
                    swLog(
                        "SNAPSHOT",
                        "dropped stale reason=\(reason) ordinal=\(activeSpace.ordinal) id=\(activeSpace.id); current ordinal=\(expectedSpace.ordinal) id=\(expectedSpace.id)"
                    )
                    return
                }
                self.applySnapshot(newSnapshot, reason: reason)
            }
        }
    }

    private func applySnapshot(_ newSnapshot: DockSnapshot, reason: String) {
        snapshot = newSnapshot
        if !hasInitialSnapshot {
            hasInitialSnapshot = true
            DispatchQueue.main.asyncAfter(deadline: .now() + bootstrapConfigDelay) { [weak self] in
                self?.configEventsEnabled = true
            }
        }
        swLog("SNAPSHOT", "applied reason=\(reason) ordinal=\(newSnapshot.spaceNumber) id=\(newSnapshot.spaceID) label=\(newSnapshot.spaceLabel) apps=\(newSnapshot.items.count)")
    }
}
