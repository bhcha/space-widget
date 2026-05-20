import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()
    private var configManager: ConfigManager?
    private var spaceEngine: SpaceEngine?
    private var stateWriter: StateWriter?
    private var panelController: SpacePanelController?
    private var menuBarController: MenuBarController?
    private var autoHideManager: AutoHideManager?
    private var dockController: DockController?
    private var dockGeometryObserver: DockGeometryObserver?
    private var windowShortcutController: WindowShortcutController?
    private var preferencesController: PreferencesWindowController?
    private var templateStore: LayoutTemplateStore?
    private var applier: LayoutApplier?
    private var spaceLayoutBridge: SpaceLayoutBridge?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS 26.5+ aggressively terminates panel-only apps via AppKit's
        // "No windows open yet" TAL path. NSPanel doesn't count as a window.
        ProcessInfo.processInfo.disableAutomaticTermination("SpaceWidget runs as a persistent panel overlay")

        let configManager = ConfigManager()

        // Create SpaceMonitor first so it can be shared
        let spaceMonitor = SpaceMonitor()
        let spaceEngine = SpaceEngine(configManager: configManager, spaceMonitor: spaceMonitor)
        let stateWriter = StateWriter()
        stateWriter.subscribe(to: spaceEngine.$snapshots, mainDisplayID: { spaceEngine.spaceMonitor.mainDisplayIdentifier })

        let autoHideManager = AutoHideManager()
        let dockController = DockController()
        let dockGeometryObserver = DockGeometryObserver()

        // Layout template objects
        let templateStore = LayoutTemplateStore()
        templateStore.load()
        let applier = LayoutApplier()
        let spaceLayoutBridge = SpaceLayoutBridge(
            spaceMonitor: spaceMonitor,
            store: templateStore,
            applier: applier
        )

        self.configManager = configManager
        self.spaceEngine = spaceEngine
        self.stateWriter = stateWriter
        self.autoHideManager = autoHideManager
        self.dockController = dockController
        self.dockGeometryObserver = dockGeometryObserver
        self.templateStore = templateStore
        self.applier = applier
        self.spaceLayoutBridge = spaceLayoutBridge
        self.panelController = SpacePanelController(spaceEngine: spaceEngine, autoHideManager: autoHideManager, dockGeometry: dockGeometryObserver)

        let preferencesController = PreferencesWindowController(
            configManager: configManager,
            templateStore: templateStore
        )
        self.preferencesController = preferencesController

        self.menuBarController = MenuBarController(
            autoHideManager: autoHideManager,
            configManager: configManager,
            dockController: dockController,
            preferencesController: preferencesController,
            templateStore: templateStore,
            applier: applier
        )

        let windowShortcutController = WindowShortcutController(
            configManager: configManager,
            templateStore: templateStore,
            applier: applier
        )
        windowShortcutController.registerShortcuts()
        self.windowShortcutController = windowShortcutController

        // Re-register shortcuts when shortcut settings change
        configManager.$shortcuts
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak windowShortcutController] _ in
                windowShortcutController?.registerShortcuts()
            }
            .store(in: &cancellables)

        // Re-register shortcuts when templates change
        templateStore.$templates
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak windowShortcutController] _ in
                windowShortcutController?.registerShortcuts()
            }
            .store(in: &cancellables)

    }

    func applicationWillTerminate(_ notification: Notification) {
        dockController?.restoreOriginal()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct SpaceWidgetApp {
    static let appDelegate = AppDelegate()

    static func main() {
        let args = CommandLine.arguments

        // --version
        if args.contains("--version") {
            print("SpaceWidget 0.1.0")
            exit(0)
        }

        // --help
        if args.contains("--help") {
            printUsage()
            exit(0)
        }

        // --config-dir <path>  (must be parsed before --migrate so migration uses the custom dir)
        if let idx = args.firstIndex(of: "--config-dir"), idx + 1 < args.count {
            let customPath = args[idx + 1]
            ConfigManager.setCustomConfigDir(customPath)
        }

        // --migrate [--force]
        if args.contains("--migrate") {
            let force = args.contains("--force")
            let code = Migrator.run(force: force)
            exit(code)
        }

        // Normal launch
        let app = NSApplication.shared
        app.delegate = appDelegate

        // No Dock icon, no Cmd+Tab appearance
        app.setActivationPolicy(.accessory)

        app.run()
    }

    // MARK: - Help Text

    private static func printUsage() {
        print("""
        SpaceWidget — macOS space-aware dock widget

        USAGE:
          SpaceWidget [OPTIONS]

        OPTIONS:
          --version            Print version and exit
          --help               Print this help and exit
          --migrate            Migrate config from ~/.config/sketchybar/ to ~/.config/space-dock/
          --migrate --force    Migrate and overwrite existing files
          --config-dir <path>  Override the config directory (default: ~/.config/space-dock)

        """)
    }
}
