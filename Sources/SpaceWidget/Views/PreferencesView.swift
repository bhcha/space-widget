import SwiftUI
import UniformTypeIdentifiers

struct PreferencesView: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var templateStore: LayoutTemplateStore
    @State private var shortcuts: [String: ShortcutBinding] = [:]
    @State private var hiddenApps: Set<String> = []
    @State private var iconCache: [String: NSImage] = [:]

    /// System apps always filtered — not shown in the UI list.
    private static let systemApps: Set<String> = [
        "System Events", "Dock", "SystemUIServer", "Control Center",
        "Notification Center", "loginwindow", "WindowManager", "TextInputMenuAgent"
    ]

    /// Default hidden apps — shown in the UI but cannot be removed.
    private static let defaultHiddenApps: Set<String> = ["SpaceWidget"]

    var body: some View {
        TabView {
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            LayoutTemplatesView(store: templateStore)
                .tabItem { Label("Layouts", systemImage: "rectangle.split.3x1") }

            hiddenAppsTab
                .tabItem { Label("Hidden Apps", systemImage: "eye.slash") }
        }
        .frame(minWidth: 580, minHeight: 660)
        .onAppear {
            shortcuts = configManager.shortcuts
            hiddenApps = configManager.ignoredApps
            loadIconCache()
        }
    }

    // MARK: - Shortcuts Tab

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts")
                .font(.headline)
                .padding(.bottom, 4)

            ForEach(WindowAction.allCases, id: \.self) { action in
                HStack {
                    Toggle("", isOn: shortcutEnabled(for: action))
                        .toggleStyle(.checkbox)
                        .frame(width: 20)

                    WindowActionIcon(action: action)

                    Text(action.displayName)
                        .frame(width: 140, alignment: .leading)

                    ShortcutRecorderView(binding: shortcutBinding(for: action))

                    Button(action: { clearShortcut(for: action) }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear shortcut")
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    shortcuts = ConfigManager.defaultShortcuts
                    save()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
    }

    // MARK: - Hidden Apps Tab

    private var hiddenAppsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hidden Apps")
                .font(.headline)
                .padding(.bottom, 4)

            Text("These apps will not appear in the space widget bar.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            let defaultApps = Self.defaultHiddenApps.sorted()
            let userApps = hiddenApps.subtracting(Self.systemApps).subtracting(Self.defaultHiddenApps).sorted()

            List {
                ForEach(defaultApps, id: \.self) { appName in
                    HStack {
                        appIconView(for: appName)
                        Text(appName)
                        Spacer()
                        Text("Default")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                ForEach(userApps, id: \.self) { appName in
                    HStack {
                        appIconView(for: appName)
                        Text(appName)
                        Spacer()
                        Button(action: { removeHiddenApp(appName) }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from hidden list")
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 200)

            HStack {
                Button("Add App...") {
                    addAppFromPicker()
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func appIconView(for appName: String) -> some View {
        if let icon = iconCache[appName] {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.fill")
                .frame(width: 20, height: 20)
        }
    }

    // MARK: - Hidden Apps Helpers

    private func addAppFromPicker() {
        let panel = NSOpenPanel()
        panel.title = "Select Application"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [UTType.application]

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            let appName = resolveAppName(from: url)
            hiddenApps.insert(appName)
            if let icon = NSWorkspace.shared.icon(forFile: url.path) as NSImage? {
                iconCache[appName] = icon
            }
        }
        saveHiddenApps()
    }

    private func removeHiddenApp(_ appName: String) {
        hiddenApps.remove(appName)
        iconCache.removeValue(forKey: appName)
        saveHiddenApps()
    }

    private func saveHiddenApps() {
        configManager.saveIgnoredApps(hiddenApps)
    }

    /// Resolve the app name that matches what WindowListProvider uses for filtering.
    /// WindowListProvider filters by CGWindowOwnerName / NSRunningApplication.localizedName,
    /// so we must store the same name. The .app filename (without extension) matches
    /// localizedName in the vast majority of cases.
    private func resolveAppName(from url: URL) -> String {
        // The .app filename without extension is the most reliable match for
        // CGWindowOwnerName / localizedName used by WindowListProvider.
        let fileBaseName = url.deletingPathExtension().lastPathComponent

        // Check if a running instance confirms the name
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL == url || $0.localizedName == fileBaseName
        }), let localizedName = app.localizedName {
            return localizedName
        }

        return fileBaseName
    }

    /// Pre-load icons for all visible hidden apps on a background queue.
    private func loadIconCache() {
        let userApps = hiddenApps.subtracting(Self.systemApps).union(Self.defaultHiddenApps)
        DispatchQueue.global(qos: .userInitiated).async {
            var cache: [String: NSImage] = [:]
            let workspace = NSWorkspace.shared
            let fm = FileManager.default

            let searchDirs = [
                "/Applications",
                "/System/Applications",
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
            ]

            for appName in userApps {
                // Direct match first
                var found = false
                for dir in searchDirs {
                    let path = "\(dir)/\(appName).app"
                    if fm.fileExists(atPath: path) {
                        cache[appName] = workspace.icon(forFile: path)
                        found = true
                        break
                    }
                }
                if found { continue }

                // Subdirectory search
                for dir in searchDirs {
                    if found { break }
                    let dirURL = URL(fileURLWithPath: dir)
                    guard let enumerator = fm.enumerator(at: dirURL,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                    for case let fileURL as URL in enumerator {
                        guard fileURL.pathExtension == "app" else { continue }
                        if fileURL.deletingPathExtension().lastPathComponent == appName {
                            cache[appName] = workspace.icon(forFile: fileURL.path)
                            found = true
                            break
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                iconCache = cache
            }
        }
    }

    // MARK: - Shortcut Helpers

    private func shortcutEnabled(for action: WindowAction) -> Binding<Bool> {
        Binding(
            get: { shortcuts[action.rawValue]?.enabled ?? true },
            set: { newValue in
                shortcuts[action.rawValue]?.enabled = newValue
                save()
            }
        )
    }

    private func shortcutBinding(for action: WindowAction) -> Binding<ShortcutBinding> {
        Binding(
            get: {
                shortcuts[action.rawValue]
                    ?? ConfigManager.defaultShortcuts[action.rawValue]
                    ?? ShortcutBinding(keyCode: 0, modifiers: 0, enabled: false)
            },
            set: { newValue in
                shortcuts[action.rawValue] = newValue
                save()
            }
        )
    }

    private func clearShortcut(for action: WindowAction) {
        shortcuts[action.rawValue] = ShortcutBinding(keyCode: 0, modifiers: 0, enabled: false)
        save()
    }

    private func save() {
        configManager.saveShortcuts(shortcuts)
    }
}
