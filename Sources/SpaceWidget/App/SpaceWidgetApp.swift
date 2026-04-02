import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var configManager: ConfigManager?
    private var spaceEngine: SpaceEngine?
    private var stateWriter: StateWriter?
    private var panelController: SpacePanelController?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configManager = ConfigManager()
        let spaceEngine = SpaceEngine(configManager: configManager)
        let stateWriter = StateWriter()
        stateWriter.subscribe(to: spaceEngine.$snapshot)

        self.configManager = configManager
        self.spaceEngine = spaceEngine
        self.stateWriter = stateWriter
        self.panelController = SpacePanelController(spaceEngine: spaceEngine)
        self.menuBarController = MenuBarController()
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
