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
    private var windowShortcutController: WindowShortcutController?
    private var preferencesController: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configManager = ConfigManager()
        let spaceEngine = SpaceEngine(configManager: configManager)
        let stateWriter = StateWriter()
        stateWriter.subscribe(to: spaceEngine.$snapshot)

        let autoHideManager = AutoHideManager()
        let dockController = DockController()

        self.configManager = configManager
        self.spaceEngine = spaceEngine
        self.stateWriter = stateWriter
        self.autoHideManager = autoHideManager
        self.dockController = dockController
        self.panelController = SpacePanelController(spaceEngine: spaceEngine, autoHideManager: autoHideManager)
        let preferencesController = PreferencesWindowController(configManager: configManager)
        self.preferencesController = preferencesController

        self.menuBarController = MenuBarController(
            autoHideManager: autoHideManager,
            configManager: configManager,
            dockController: dockController,
            preferencesController: preferencesController
        )

        let windowShortcutController = WindowShortcutController(configManager: configManager)
        windowShortcutController.registerShortcuts()
        self.windowShortcutController = windowShortcutController

        // Re-register shortcuts when settings change
        configManager.$shortcuts
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
