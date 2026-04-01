import Foundation

enum Migrator {

    // MARK: - Public Entry Point

    /// Migrate old sketchybar-based config to the active config directory
    /// (respects `--config-dir` via `ConfigManager.configDir`).
    /// - Parameter force: Overwrite existing destination files when true.
    /// - Returns: exit code (0 = success, 1 = nothing found / error)
    @discardableResult
    static func run(force: Bool) -> Int32 {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let srcDir = home.appendingPathComponent(".config/sketchybar", isDirectory: true)
        let dstDir = ConfigManager.configDir

        // Resolve to standardized paths for comparison
        let srcPath = srcDir.standardizedFileURL.path
        let dstPath = dstDir.standardizedFileURL.path
        if srcPath == dstPath {
            print("[migrate] Error: source and destination are the same directory (\(srcPath))")
            return 1
        }

        guard fm.fileExists(atPath: srcDir.path) else {
            print("[migrate] Nothing to migrate: \(srcDir.path) does not exist.")
            return 1
        }

        // Ensure destination directory exists
        do {
            try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        } catch {
            print("[migrate] Failed to create config dir: \(error.localizedDescription)")
            return 1
        }

        var didMigrateAny = false

        // 1. ignored_apps.lua → ignored_apps.json
        let ignoredSrc = srcDir.appendingPathComponent("ignored_apps.lua")
        let ignoredDst = dstDir.appendingPathComponent("ignored_apps.json")
        if fm.fileExists(atPath: ignoredSrc.path) {
            if fm.fileExists(atPath: ignoredDst.path) && !force {
                print("[migrate] Skipping ignored_apps.json — already exists (use --force to overwrite)")
            } else {
                if migrateIgnoredApps(src: ignoredSrc, dst: ignoredDst) {
                    print("[migrate] ignored_apps.lua → ignored_apps.json")
                    didMigrateAny = true
                }
            }
        }

        // 2. space_labels.lua → space_labels.json
        let labelsSrc = srcDir.appendingPathComponent("space_labels.lua")
        let labelsDst = dstDir.appendingPathComponent("space_labels.json")
        if fm.fileExists(atPath: labelsSrc.path) {
            if fm.fileExists(atPath: labelsDst.path) && !force {
                print("[migrate] Skipping space_labels.json — already exists (use --force to overwrite)")
            } else {
                if migrateSpaceLabels(src: labelsSrc, dst: labelsDst) {
                    print("[migrate] space_labels.lua → space_labels.json")
                    didMigrateAny = true
                }
            }
        }

        // 3. app_actions.json → app_actions.json (direct copy)
        let actionsSrc = srcDir.appendingPathComponent("app_actions.json")
        let actionsDst = dstDir.appendingPathComponent("app_actions.json")
        if fm.fileExists(atPath: actionsSrc.path) {
            if fm.fileExists(atPath: actionsDst.path) && !force {
                print("[migrate] Skipping app_actions.json — already exists (use --force to overwrite)")
            } else {
                do {
                    if fm.fileExists(atPath: actionsDst.path) {
                        try fm.removeItem(at: actionsDst)
                    }
                    try fm.copyItem(at: actionsSrc, to: actionsDst)
                    print("[migrate] app_actions.json copied")
                    didMigrateAny = true
                } catch {
                    print("[migrate] Failed to copy app_actions.json: \(error.localizedDescription)")
                }
            }
        }

        if didMigrateAny {
            print("[migrate] Done. Config written to \(dstDir.path)")
            return 0
        } else {
            print("[migrate] No source files found in \(srcDir.path)")
            return 1
        }
    }

    // MARK: - ignored_apps.lua Parser

    /// Parses lines like:
    ///   ["App Name"] = true,
    ///   [App Name] = true,
    ///   App Name = true,
    private static func migrateIgnoredApps(src: URL, dst: URL) -> Bool {
        guard let text = try? String(contentsOf: src, encoding: .utf8) else {
            print("[migrate] Cannot read \(src.lastPathComponent)")
            return false
        }

        var apps: [String] = []

        // Match: ["Some App"] = true  or  [Some App] = true  or  SomApp = true
        // Key may be quoted with double-quotes inside brackets, or bare identifier
        let pattern = #"(?:(?:\[(?:"([^"]+)"|([^\]]+))\])|([A-Za-z][A-Za-z0-9 _-]*))\s*=\s*true"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }

        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip comments and return statement
            if trimmed.hasPrefix("--") || trimmed.hasPrefix("return") || trimmed.isEmpty { continue }

            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: range) {
                let name = capturedGroup(match, in: trimmed, at: [1, 2, 3])
                if let name = name, !name.isEmpty {
                    apps.append(name)
                }
            }
        }

        apps = apps.sorted()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(apps) else { return false }

        do {
            try data.write(to: dst, options: .atomic)
            return true
        } catch {
            print("[migrate] Write failed for ignored_apps.json: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - space_labels.lua Parser

    /// Parses lines like:
    ///   [1] = "Work",
    ///   ["1"] = "Work",
    private static func migrateSpaceLabels(src: URL, dst: URL) -> Bool {
        guard let text = try? String(contentsOf: src, encoding: .utf8) else {
            print("[migrate] Cannot read \(src.lastPathComponent)")
            return false
        }

        var labels: [String: String] = [:]

        // Match: [1] = "Label"  or  ["1"] = "Label"
        let pattern = #"\[(?:"?(\d+)"?)\]\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }

        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("--") || trimmed.hasPrefix("return") || trimmed.isEmpty { continue }

            let nsLine = trimmed as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            if let match = regex.firstMatch(in: trimmed, range: range) {
                let keyRange = match.range(at: 1)
                let valRange = match.range(at: 2)
                if keyRange.location != NSNotFound, valRange.location != NSNotFound {
                    let key = nsLine.substring(with: keyRange)
                    let value = nsLine.substring(with: valRange)
                    labels[key] = value
                }
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(labels) else { return false }

        do {
            try data.write(to: dst, options: .atomic)
            return true
        } catch {
            print("[migrate] Write failed for space_labels.json: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Helpers

    private static func capturedGroup(_ match: NSTextCheckingResult, in str: String, at indices: [Int]) -> String? {
        let ns = str as NSString
        for i in indices {
            let r = match.range(at: i)
            if r.location != NSNotFound {
                let captured = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
                if !captured.isEmpty { return captured }
            }
        }
        return nil
    }
}
