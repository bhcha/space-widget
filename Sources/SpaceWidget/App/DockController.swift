import Foundation

enum DockMode: String, Codable {
    case autoHide = "auto_hide"
    case alwaysHide = "always_hide"
    case alwaysShow = "always_show"
}

final class DockController {
    private let bridge: CoreDockBridge?
    private var originalAutoHide: Bool?
    private var originalDelay: Double?
    private var originalTimeModifier: Double?

    init() {
        bridge = CoreDockBridge()
        // Save original Dock state for restore on quit
        originalAutoHide = bridge?.getAutoHideEnabled()
        originalDelay = readDefault("autohide-delay")
        originalTimeModifier = readDefault("autohide-time-modifier")
    }

    var currentAutoHide: Bool {
        bridge?.getAutoHideEnabled() ?? false
    }

    var currentMode: DockMode {
        guard currentAutoHide else { return .alwaysShow }
        if let delay = readDefault("autohide-delay"), delay > 999 {
            return .alwaysHide
        }
        return .autoHide
    }

    func apply(mode: DockMode) {
        // Check if Dock has a large delay BEFORE making changes
        let hadLargeDelay = readDefault("autohide-delay").map { $0 > 999 } ?? false

        switch mode {
        case .autoHide:
            bridge?.setAutoHideEnabled(true)
            deleteDefault("autohide-delay")
            deleteDefault("autohide-time-modifier")
            if hadLargeDelay { restartDock() }

        case .alwaysHide:
            bridge?.setAutoHideEnabled(true)
            writeDefault("autohide-delay", value: "1000000")
            writeDefault("autohide-time-modifier", value: "0")
            restartDock()

        case .alwaysShow:
            bridge?.setAutoHideEnabled(false)
            deleteDefault("autohide-delay")
            deleteDefault("autohide-time-modifier")
            if hadLargeDelay { restartDock() }
        }
    }

    /// Restore original Dock settings (called on app quit)
    func restoreOriginal() {
        // Read current delay BEFORE writing back originals
        let needsRestart = readDefault("autohide-delay").map { $0 > 999 } ?? false

        if let orig = originalAutoHide {
            bridge?.setAutoHideEnabled(orig)
        }
        if let delay = originalDelay {
            writeDefault("autohide-delay", value: String(delay))
        } else {
            deleteDefault("autohide-delay")
        }
        if let modifier = originalTimeModifier {
            writeDefault("autohide-time-modifier", value: String(modifier))
        } else {
            deleteDefault("autohide-time-modifier")
        }
        if needsRestart {
            restartDock()
        }
    }

    // MARK: - Private

    func readDefault(_ key: String) -> Double? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", "com.apple.dock", key]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Double(str)
        } catch {
            return nil
        }
    }

    private func writeDefault(_ key: String, value: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", "com.apple.dock", key, "-float", value]
        try? task.run()
        task.waitUntilExit()
    }

    private func deleteDefault(_ key: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["delete", "com.apple.dock", key]
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    private func restartDock() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        try? task.run()
    }
}
