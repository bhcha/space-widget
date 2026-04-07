import Foundation
import Combine
import os.lock

final class ConfigManager: ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var ignoredApps: Set<String> = []
    @Published private(set) var spaceLabels: [Int: String] = [:]
    @Published private(set) var appActions: [String: [String: String]] = [:]
    static let iconsPerPageRange = 5...10
    static let defaultIconsPerPage = 5
    @Published private(set) var iconsPerPage: Int = defaultIconsPerPage

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

    // MARK: - Defaults

    private static let defaultIgnoredApps: [String] = [
        "System Events",
        "Dock",
        "SystemUIServer",
        "Control Center",
        "Notification Center",
        "loginwindow",
        "WindowManager",
        "TextInputMenuAgent"
    ]

    private static let defaultSpaceLabels: [String: String] = [
        "1": "Work",
        "2": "Browse"
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
        spaceLabels = loadSpaceLabels()
        appActions = loadAppActions()
        let rawIPP = loadSettings()["icons_per_page"] ?? Self.defaultIconsPerPage
        iconsPerPage = Swift.min(Swift.max(rawIPP, Self.iconsPerPageRange.lowerBound), Self.iconsPerPageRange.upperBound)
    }

    func load() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.ensureConfigDirectoryAndDefaults()
            self.writeActiveConfigDirState()

            let ignored = self.loadIgnoredApps()
            let labels = self.loadSpaceLabels()
            let actions = self.loadAppActions()
            let rawIPP = self.loadSettings()["icons_per_page"] ?? Self.defaultIconsPerPage
            let ipp = Swift.min(Swift.max(rawIPP, Self.iconsPerPageRange.lowerBound), Self.iconsPerPageRange.upperBound)

            DispatchQueue.main.async {
                if self.ignoredApps != ignored {
                    self.ignoredApps = ignored
                }
                if self.spaceLabels != labels {
                    self.spaceLabels = labels
                }
                if self.appActions != actions {
                    self.appActions = actions
                }
                if self.iconsPerPage != ipp {
                    self.iconsPerPage = ipp
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

    func saveSpaceLabels(_ labels: [Int: String]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            // JSON keys must be strings
            let stringKeyed = Dictionary(uniqueKeysWithValues: labels.map { ("\($0.key)", $0.value) })
            guard let data = try? JSONEncoder().encode(stringKeyed) else { return }
            self.atomicWrite(data: data, to: self.spaceLabelsURL)
            DispatchQueue.main.async {
                self.spaceLabels = labels
            }
        }
    }

    func updateSpaceLabel(ordinal: Int, label: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateSpaceLabel(ordinal: ordinal, label: label) }
            return
        }
        var updated = spaceLabels
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            updated.removeValue(forKey: ordinal)
        } else {
            updated[ordinal] = trimmed
        }
        saveSpaceLabels(updated)
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

    // MARK: - Private: File Loading

    private func loadIgnoredApps() -> Set<String> {
        guard let data = try? Data(contentsOf: ignoredAppsURL),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return Set(Self.defaultIgnoredApps)
        }
        return Set(array)
    }

    private func loadSpaceLabels() -> [Int: String] {
        guard let data = try? Data(contentsOf: spaceLabelsURL),
              let stringKeyed = try? JSONDecoder().decode([String: String].self, from: data) else {
            return Dictionary(uniqueKeysWithValues: Self.defaultSpaceLabels.compactMap { k, v in
                guard let i = Int(k) else { return nil }
                return (i, v)
            })
        }
        return Dictionary(uniqueKeysWithValues: stringKeyed.compactMap { k, v in
            guard let i = Int(k) else { return nil }
            return (i, v)
        })
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

        // Create default space_labels.json if missing
        if !fm.fileExists(atPath: spaceLabelsURL.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(Self.defaultSpaceLabels) {
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
