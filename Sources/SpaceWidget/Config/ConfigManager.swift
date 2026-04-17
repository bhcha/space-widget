import Foundation
import Combine
import os.lock

// MARK: - Space Label Models (v2)

struct SpaceLabelEntry: Codable, Equatable {
    var spaceID: UInt64
    var displayID: String
    var ordinal: Int
    var label: String

    enum CodingKeys: String, CodingKey {
        case spaceID = "space_id"
        case displayID = "display_id"
        case ordinal
        case label
    }
}

struct SpaceLabelsFile: Codable {
    var version: Int
    var entries: [SpaceLabelEntry]
}

// MARK: -

final class ConfigManager: ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var ignoredApps: Set<String> = []
    @Published private(set) var spaceLabelEntries: [SpaceLabelEntry] = []
    @Published private(set) var appActions: [String: [String: String]] = [:]
    static let iconsPerPageRange = 5...10
    static let defaultIconsPerPage = 5
    @Published private(set) var iconsPerPage: Int = defaultIconsPerPage
    @Published private(set) var shortcuts: [String: ShortcutBinding] = defaultShortcuts
    @Published private(set) var overlapDetection: OverlapDetection = .default
    private(set) var liveDisplayIDs: Set<String> = []

    static let defaultShortcuts: [String: ShortcutBinding] = [
        "leftHalf": ShortcutBinding(keyCode: 0x7B, modifiers: 0x1800, enabled: true),
        "rightHalf": ShortcutBinding(keyCode: 0x7C, modifiers: 0x1800, enabled: true),
        "maximize": ShortcutBinding(keyCode: 0x24, modifiers: 0x1800, enabled: true),
        "firstThird": ShortcutBinding(keyCode: 0x02, modifiers: 0x1800, enabled: true),
        "centerThird": ShortcutBinding(keyCode: 0x03, modifiers: 0x1800, enabled: true),
        "lastThird": ShortcutBinding(keyCode: 0x05, modifiers: 0x1800, enabled: true),
        "firstTwoThirds": ShortcutBinding(keyCode: 0x0E, modifiers: 0x1800, enabled: true),
        "centerTwoThirds": ShortcutBinding(keyCode: 0x08, modifiers: 0x1800, enabled: true),
        "lastTwoThirds": ShortcutBinding(keyCode: 0x11, modifiers: 0x1800, enabled: true),
        "minimize": ShortcutBinding(keyCode: 0x35, modifiers: 0x1800, enabled: true),
    ]

    // MARK: - Paths

    private static var _customConfigDir: URL?
    private static var _customConfigDirLock = os_unfair_lock()

    static var configDir: URL {
        os_unfair_lock_lock(&_customConfigDirLock)
        let custom = _customConfigDir
        os_unfair_lock_unlock(&_customConfigDirLock)
        if let custom = custom { return custom }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/space-dock", isDirectory: true)
    }

    /// Override the config directory. Must be called before the first ConfigManager init.
    static func setCustomConfigDir(_ path: String) {
        os_unfair_lock_lock(&_customConfigDirLock)
        _customConfigDir = URL(fileURLWithPath: path, isDirectory: true)
        os_unfair_lock_unlock(&_customConfigDirLock)
    }

    private var ignoredAppsURL: URL { Self.configDir.appendingPathComponent("ignored_apps.json") }
    private var spaceLabelsURL: URL { Self.configDir.appendingPathComponent("space_labels.json") }
    private var appActionsURL: URL { Self.configDir.appendingPathComponent("app_actions.json") }
    private var settingsURL: URL { Self.configDir.appendingPathComponent("settings.json") }
    private var shortcutsURL: URL { Self.configDir.appendingPathComponent("shortcuts.json") }
    private var overlapDetectionURL: URL { Self.configDir.appendingPathComponent("overlap_detection.json") }

    // MARK: - Defaults

    private static let defaultIgnoredApps: [String] = [
        "System Events",
        "Dock",
        "SystemUIServer",
        "Control Center",
        "Notification Center",
        "loginwindow",
        "WindowManager",
        "TextInputMenuAgent",
        "SpaceWidget"
    ]

    private static let defaultAppActions: [String: [String: String]] = [
        "new": [
            "com.apple.finder": "finder_new_window",
            "com.googlecode.iterm2": "iterm2_new_window",
            "com.google.Chrome": "chrome_new_window"
        ],
        "quit": [:]
    ]

    // MARK: - Internal State

    private let queue = DispatchQueue(label: "com.spacedock.configmanager", qos: .utility)

    // Flag set briefly while the app itself writes config to suppress self-triggered reloads
    var isSelfWriting: Bool = false

    // Set when a reload is requested during a self-write window; executed once the window closes
    private var pendingReload: Bool = false

    // MARK: - Init

    init() {
        loadInitialState()
    }

    // MARK: - Load

    private func loadInitialState() {
        ensureConfigDirectoryAndDefaults()
        writeActiveConfigDirState()
        ignoredApps = loadIgnoredApps()
        spaceLabelEntries = loadSpaceLabelEntries()
        appActions = loadAppActions()
        let rawIPP = loadSettings()["icons_per_page"] ?? Self.defaultIconsPerPage
        iconsPerPage = Swift.min(Swift.max(rawIPP, Self.iconsPerPageRange.lowerBound), Self.iconsPerPageRange.upperBound)
        shortcuts = loadShortcuts()
        overlapDetection = loadOverlapDetection()
    }

    func load() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.ensureConfigDirectoryAndDefaults()
            self.writeActiveConfigDirState()

            let ignored = self.loadIgnoredApps()
            let entries = self.loadSpaceLabelEntries()
            let actions = self.loadAppActions()
            let rawIPP = self.loadSettings()["icons_per_page"] ?? Self.defaultIconsPerPage
            let ipp = Swift.min(Swift.max(rawIPP, Self.iconsPerPageRange.lowerBound), Self.iconsPerPageRange.upperBound)
            let loadedShortcuts = self.loadShortcuts()
            let loadedOverlapDetection = self.loadOverlapDetection()

            DispatchQueue.main.async {
                if self.ignoredApps != ignored {
                    self.ignoredApps = ignored
                }
                if self.spaceLabelEntries != entries {
                    self.spaceLabelEntries = entries
                }
                if self.appActions != actions {
                    self.appActions = actions
                }
                if self.iconsPerPage != ipp {
                    self.iconsPerPage = ipp
                }
                if self.shortcuts != loadedShortcuts {
                    self.shortcuts = loadedShortcuts
                }
                if self.overlapDetection != loadedOverlapDetection {
                    self.overlapDetection = loadedOverlapDetection
                }
            }
        }
    }

    func reload() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.reload() }
            return
        }
        guard !isSelfWriting else {
            pendingReload = true
            return
        }
        load()
    }

    // MARK: - Save: Ignored Apps

    func saveIgnoredApps(_ apps: Set<String>) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let array = apps.sorted()
            guard let data = try? JSONEncoder().encode(array) else { return }
            self.atomicWrite(data: data, to: self.ignoredAppsURL)
            DispatchQueue.main.async {
                self.ignoredApps = apps
            }
        }
    }

    // MARK: - Save: Space Labels

    /// Apply new entries: updates published property synchronously on main, queues file write async.
    /// Caller must be on main thread (or this dispatches to main).
    private func applySpaceLabelEntries(_ entries: [SpaceLabelEntry]) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.applySpaceLabelEntries(entries)
            }
            return
        }
        // Sync publish FIRST so subsequent reads (even within the same main run loop tick) see the update
        if self.spaceLabelEntries != entries {
            self.spaceLabelEntries = entries
        }
        // Queue async file write
        queue.async { [weak self] in
            guard let self = self else { return }
            let file = SpaceLabelsFile(version: 2, entries: entries)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(file) else { return }
            self.atomicWrite(data: data, to: self.spaceLabelsURL)
        }
    }

    /// Look up the label for a given display/space. Prefers spaceID match, falls back to ordinal match on the same display.
    /// Pass mainDisplayID so that migrated v1 entries stored under "__main__" sentinel are also resolved.
    func labelFor(displayID: String, spaceID: UInt64, ordinal: Int, mainDisplayID: String) -> String? {
        let candidates = [displayID, displayID == mainDisplayID ? "__main__" : nil].compactMap { $0 }

        // Tier 0: dead-display override (read-only, non-destructive).
        // In single-display mode, if a disconnected display had MORE labels than the
        // current display, prefer the dead display's label by ordinal. This handles
        // unplugging a primary monitor: the secondary (now sole) display should show
        // the primary's workspace labels instead of its own minimal set.
        // Skip if the current display already has a label for this specific spaceID
        // (user edited it after disconnecting — that edit takes priority).
        if liveDisplayIDs.count <= 1 {
            let hasOwnLabelForSpace = spaceID != 0 && spaceLabelEntries.contains(where: {
                candidates.contains($0.displayID) && $0.spaceID == spaceID && !$0.label.isEmpty
            })
            if !hasOwnLabelForSpace {
                let ownLabelCount = spaceLabelEntries.filter { candidates.contains($0.displayID) && !$0.label.isEmpty }.count
                let deadEntries = spaceLabelEntries.filter { !liveDisplayIDs.contains($0.displayID) && $0.displayID != "__main__" }
                let deadByDisplay = Dictionary(grouping: deadEntries.filter { !$0.label.isEmpty }, by: { $0.displayID })
                if let (_, entries) = deadByDisplay.max(by: { $0.value.count < $1.value.count }),
                   entries.count > ownLabelCount,
                   let entry = entries.first(where: { $0.ordinal == ordinal }) {
                    return entry.label
                }
            }
        }

        // Tier 1: spaceID match on same display (session-stable)
        if spaceID != 0, let entry = spaceLabelEntries.first(where: { candidates.contains($0.displayID) && $0.spaceID == spaceID }) {
            return entry.label.isEmpty ? nil : entry.label
        }
        // Tier 2: ordinal fallback on same display — only sentinel entries (spaceID == 0)
        if let entry = spaceLabelEntries.first(where: { candidates.contains($0.displayID) && $0.ordinal == ordinal && $0.spaceID == 0 }) {
            return entry.label.isEmpty ? nil : entry.label
        }
        return nil
    }

    /// Update or insert a label for a specific space. Must be called on main.
    func updateSpaceLabel(displayID: String, spaceID: UInt64, ordinal: Int, label: String, mainDisplayID: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateSpaceLabel(displayID: displayID, spaceID: spaceID, ordinal: ordinal, label: label, mainDisplayID: mainDisplayID)
            }
            return
        }
        var updated = spaceLabelEntries
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)

        // Resolve sentinel: a v1-migrated entry stored under "__main__" for the main display
        let sentinelDisplayID = displayID == mainDisplayID ? "__main__" : nil

        // Find existing entry: first try (displayID, spaceID), then (displayID, ordinal),
        // then sentinel (__main__, ordinal) for migrated v1 entries on the main display.
        let idxBySpaceID: Int? = spaceID != 0
            ? updated.firstIndex { $0.displayID == displayID && $0.spaceID == spaceID }
            : nil
        let idxByOrdinal: Int? = updated.firstIndex { $0.displayID == displayID && $0.ordinal == ordinal }
        let idxBySentinel: Int? = sentinelDisplayID.flatMap { sid in
            updated.firstIndex { $0.displayID == sid && $0.ordinal == ordinal }
        }

        // Prefer spaceID match, then real-displayID ordinal, then sentinel
        let idx: Int? = idxBySpaceID ?? idxByOrdinal ?? idxBySentinel

        if trimmed.isEmpty {
            if let idx = idx { updated.remove(at: idx) }
        } else {
            let entry = SpaceLabelEntry(spaceID: spaceID, displayID: displayID, ordinal: ordinal, label: trimmed)
            if let idx = idx {
                // If this was a sentinel entry, remove it and append the real entry so the sentinel is gone
                if updated[idx].displayID == "__main__" {
                    updated.remove(at: idx)
                    updated.append(entry)
                } else {
                    updated[idx] = entry
                }
            } else {
                updated.append(entry)
            }
        }
        applySpaceLabelEntries(updated)
    }

    /// Update the set of currently connected displays. Called from screen-change observers
    /// so that labelFor()'s dead-display fallback stays current even before a space change fires.
    func updateLiveDisplays(_ displayIDs: Set<String>) {
        liveDisplayIDs = displayIDs
    }

    /// Rebind stored entries against live per-display space lists in a single atomic update.
    /// This is the correct API when multiple displays need rebinding — avoids the race
    /// where looping per-display calls each reads a stale array.
    func rebindAllOrdinals(
        displayLists: [String: [(spaceID: UInt64, ordinal: Int)]],
        mainDisplayID: String
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.rebindAllOrdinals(displayLists: displayLists, mainDisplayID: mainDisplayID)
            }
            return
        }

        // Track live displays for labelFor() read-time fallback
        liveDisplayIDs = Set(displayLists.keys)

        var updated = spaceLabelEntries
        var changed = false

        for (displayID, liveSpaces) in displayLists {
            let liveSpaceIDs = Set(liveSpaces.map { $0.spaceID })
            let isMain = (displayID == mainDisplayID)

            func entryBelongsToDisplay(_ entry: SpaceLabelEntry) -> Bool {
                if entry.displayID == displayID { return true }
                if isMain && entry.displayID == "__main__" { return true }
                return false
            }

            for live in liveSpaces {
                // Step 1: entry already bound to this live spaceID on same display
                if let idx = updated.firstIndex(where: {
                    entryBelongsToDisplay($0) && $0.spaceID == live.spaceID && $0.spaceID != 0
                }) {
                    if updated[idx].ordinal != live.ordinal {
                        updated[idx].ordinal = live.ordinal
                        changed = true
                    }
                    if updated[idx].displayID != displayID {
                        updated[idx].displayID = displayID
                        changed = true
                    }
                    continue
                }

                // Step 2: rebind same-display ordinal-match entry whose spaceID is 0 or dead
                if let idx = updated.firstIndex(where: {
                    entryBelongsToDisplay($0)
                        && $0.ordinal == live.ordinal
                        && ($0.spaceID == 0 || !liveSpaceIDs.contains($0.spaceID))
                }) {
                    updated[idx].spaceID = live.spaceID
                    if updated[idx].displayID != displayID {
                        updated[idx].displayID = displayID
                    }
                    changed = true
                }
            }
        }

        if changed {
            applySpaceLabelEntries(updated)
        }
    }

    /// Refresh ordinal for an observed (displayID, spaceID) pair. Called when SpaceMonitor commits fresh metadata.
    /// Keeps ordinal fallback accurate for known spaces even as macOS reorders them.
    func refreshOrdinal(displayID: String, spaceID: UInt64, ordinal: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.refreshOrdinal(displayID: displayID, spaceID: spaceID, ordinal: ordinal)
            }
            return
        }
        guard spaceID != 0 else { return }
        guard let idx = spaceLabelEntries.firstIndex(where: { $0.displayID == displayID && $0.spaceID == spaceID }) else { return }
        if spaceLabelEntries[idx].ordinal != ordinal {
            var updated = spaceLabelEntries
            updated[idx].ordinal = ordinal
            applySpaceLabelEntries(updated)
        }
    }

    // MARK: - Save: App Actions

    func saveAppActions(_ actions: [String: [String: String]]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(actions) else { return }
            self.atomicWrite(data: data, to: self.appActionsURL)
            DispatchQueue.main.async {
                self.appActions = actions
            }
        }
    }

    // MARK: - Save: Settings (Icons per Page)

    func saveIconsPerPage(_ count: Int) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let clamped = min(max(count, Self.iconsPerPageRange.lowerBound), Self.iconsPerPageRange.upperBound)
            var settings = self.loadSettings()
            settings["icons_per_page"] = clamped
            guard let data = try? JSONEncoder().encode(settings) else { return }
            self.atomicWrite(data: data, to: self.settingsURL)
            DispatchQueue.main.async {
                self.iconsPerPage = clamped
            }
        }
    }

    // MARK: - Save: Shortcuts

    func saveShortcuts(_ newShortcuts: [String: ShortcutBinding]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(newShortcuts) else { return }
            self.atomicWrite(data: data, to: self.shortcutsURL)
            DispatchQueue.main.async {
                self.shortcuts = newShortcuts
            }
        }
    }

    // MARK: - Save: Overlap Detection

    func saveOverlapDetection(_ value: OverlapDetection) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let clamped = value.clamped()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(clamped) else { return }
            self.atomicWrite(data: data, to: self.overlapDetectionURL)
            DispatchQueue.main.async {
                self.overlapDetection = clamped
            }
        }
    }

    // MARK: - Private: File Loading

    private func loadIgnoredApps() -> Set<String> {
        guard let data = try? Data(contentsOf: ignoredAppsURL),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return Set(Self.defaultIgnoredApps)
        }
        // Ensure default ignored apps are always included
        return Set(array).union(Self.defaultIgnoredApps)
    }

    private func loadSpaceLabelEntries() -> [SpaceLabelEntry] {
        guard let data = try? Data(contentsOf: spaceLabelsURL) else {
            return []
        }
        // Try v2 first (version >= 2 or even unknown future versions — forward compat)
        if let file = try? JSONDecoder().decode(SpaceLabelsFile.self, from: data),
           file.version >= 2 {
            return file.entries
        }
        // Migrate from v1: flat [String: String]
        guard let v1 = try? JSONDecoder().decode([String: String].self, from: data) else {
            NSLog("[ConfigManager] space_labels.json could not be decoded as v1 or v2 — starting empty")
            return []
        }
        return migrateV1Labels(v1)
    }

    /// Migration: convert v1 flat dict into v2 entries.
    /// Without current space state we can't resolve spaceIDs, so entries are written with spaceID=0
    /// and serve as ordinal-fallback. They will be upgraded to real spaceIDs on the next edit.
    private func migrateV1Labels(_ v1: [String: String]) -> [SpaceLabelEntry] {
        var entries: [SpaceLabelEntry] = []
        for (key, label) in v1 {
            if key.contains(":") {
                // Extended display key: "displayID:ordinal"
                let parts = key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2, let ordinal = Int(parts[1]) else { continue }
                let displayID = String(parts[0])
                entries.append(SpaceLabelEntry(spaceID: 0, displayID: displayID, ordinal: ordinal, label: label))
            } else if let ordinal = Int(key) {
                // Main display key: plain ordinal → use sentinel so lookup can match it
                entries.append(SpaceLabelEntry(spaceID: 0, displayID: "__main__", ordinal: ordinal, label: label))
            }
        }
        // Backup the v1 file before overwriting
        let backupURL = spaceLabelsURL.appendingPathExtension("v1.bak")
        if let original = try? Data(contentsOf: spaceLabelsURL) {
            try? original.write(to: backupURL, options: .atomic)
        }
        // Write v2 immediately so next launch loads cleanly
        let file = SpaceLabelsFile(version: 2, entries: entries)
        if let encoded = try? JSONEncoder().encode(file) {
            try? encoded.write(to: spaceLabelsURL, options: .atomic)
        }
        return entries
    }

    private func loadAppActions() -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: appActionsURL),
              let actions = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return Self.defaultAppActions
        }
        return actions
    }

    private func loadSettings() -> [String: Int] {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return settings
    }

    private func loadShortcuts() -> [String: ShortcutBinding] {
        guard let data = try? Data(contentsOf: shortcutsURL),
              let loaded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data)
        else { return Self.defaultShortcuts }
        var merged = Self.defaultShortcuts
        for (key, value) in loaded { merged[key] = value }
        return merged
    }

    private func loadOverlapDetection() -> OverlapDetection {
        guard let data = try? Data(contentsOf: overlapDetectionURL),
              let loaded = try? JSONDecoder().decode(OverlapDetection.self, from: data)
        else { return .default }
        return loaded.clamped()
    }

    // MARK: - Private: Directory & Defaults

    private func ensureConfigDirectoryAndDefaults() {
        let fm = FileManager.default
        let dir = Self.configDir.path

        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
        }

        // Create default ignored_apps.json if missing
        if !fm.fileExists(atPath: ignoredAppsURL.path) {
            if let data = try? JSONEncoder().encode(Self.defaultIgnoredApps.sorted()) {
                atomicWrite(data: data, to: ignoredAppsURL)
            }
        }

        // Create default space_labels.json if missing (empty v2 file)
        if !fm.fileExists(atPath: spaceLabelsURL.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let defaultFile = SpaceLabelsFile(version: 2, entries: [])
            if let data = try? encoder.encode(defaultFile) {
                atomicWrite(data: data, to: spaceLabelsURL)
            }
        }

        // Create default app_actions.json if missing
        if !fm.fileExists(atPath: appActionsURL.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(Self.defaultAppActions) {
                atomicWrite(data: data, to: appActionsURL)
            }
        }

        // Create default settings.json if missing
        if !fm.fileExists(atPath: settingsURL.path) {
            let defaults: [String: Int] = ["icons_per_page": Self.defaultIconsPerPage]
            if let data = try? JSONEncoder().encode(defaults) {
                atomicWrite(data: data, to: settingsURL)
            }
        }

        if !fm.fileExists(atPath: shortcutsURL.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(Self.defaultShortcuts) {
                atomicWrite(data: data, to: shortcutsURL)
            }
        }

        if !fm.fileExists(atPath: overlapDetectionURL.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(OverlapDetection.default) {
                atomicWrite(data: data, to: overlapDetectionURL)
            }
        }
    }

    // MARK: - Private: Active Config Dir State

    /// Writes the active config directory path to ~/.local/state/space-dock/config-dir
    /// so that helper scripts can discover it without needing env vars.
    private func writeActiveConfigDirState() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let stateDir = home
            .appendingPathComponent(".local/state/space-dock", isDirectory: true)
        do {
            try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
            let stateFile = stateDir.appendingPathComponent("config-dir")
            let payload: [String: Any] = [
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "config_dir": Self.configDir.path
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: stateFile, options: .atomic)
        } catch {
            NSLog("[ConfigManager] Failed to write config-dir state: %@", error.localizedDescription)
        }
    }

    // MARK: - Private: Atomic Write

    private func atomicWrite(data: Data, to url: URL) {
        // Set the flag on main before writing so reload() always sees a consistent value
        if Thread.isMainThread {
            self.isSelfWriting = true
        } else {
            DispatchQueue.main.sync { self.isSelfWriting = true }
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[ConfigManager] Write failed for %@: %@", url.lastPathComponent, error.localizedDescription)
        }

        // Clear flag shortly after — file system notifications are async
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.isSelfWriting = false
            if self.pendingReload {
                self.pendingReload = false
                self.load()
            }
        }
    }
}
