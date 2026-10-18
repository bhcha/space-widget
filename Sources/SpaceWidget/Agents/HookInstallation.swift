import Foundation
import CryptoKit
import Darwin

/// No constructor or inspection method writes files. Only explicit install/uninstall actions mutate.
enum HookInstallationState: Equatable {
    case installable, updateAvailable, installing, failure(String), pendingTrust, awaitingExecution, connected, uninstalled

    var label: String {
        switch self {
        case .installable: return "Ready to install"
        case .updateAvailable: return "Update available · Capture the task's Space"
        case .installing: return "Installing..."
        case .failure(let message): return "Failed · \(message)"
        case .pendingTrust: return "Installed · Check approval in Codex"
        case .awaitingExecution: return "Installed · Waiting for a hook in a new session"
        case .connected: return "Connected · Hook execution confirmed"
        case .uninstalled: return "Removed"
        }
    }
}

enum HookInstallationError: LocalizedError {
    case invalid(String), changed, busy
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .changed: return "Another process changed the configuration. Please try again."
        case .busy: return "Another installation is in progress."
        }
    }
}

struct HookInstallationReceipt: Codable {
    let configurationDigest: String
    let helperDigest: String
}

struct HookInstallation {
    static let currentHelperVersion = 6
    let agent: LocalAgent
    let directory: URL
    let helperVersion: Int
    init(agent: LocalAgent, directory: URL, helperVersion: Int = Self.currentHelperVersion) {
        self.agent = agent
        self.directory = directory
        self.helperVersion = helperVersion
    }
    private var managedEvents: [String] { helperVersion == 1 ? ["SessionStart", "Stop"] : Self.events }
    /// Durable per-configuration location; independent of the checkout or application bundle.
    var support: URL { directory.appendingPathComponent("spacewidget-hooks", isDirectory: true) }
    var helper: URL { support.appendingPathComponent("receiver-v\(helperVersion)") }
    var helperHash: URL { support.appendingPathComponent("receiver-v\(helperVersion).sha256") }
    var file: URL { directory.appendingPathComponent(agent == .codex ? "hooks.json" : "settings.json") }
    var receipt: URL { support.appendingPathComponent("execution.json") }
    static let events = ["SessionStart", "UserPromptSubmit", "Stop"]
    static let maximumConfigBytes = 4 * 1024 * 1024

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func command(for event: String) -> String {
        // No payload interpolation, PATH lookup, cwd assumption or trust bypass. Missing/broken
        // helpers are harmless. Timeout is also enforced by the native receiver itself.
        let invocation = "\(Self.quote(helper.path)) --spacewidget-hook \(Self.quote(agent.rawValue)) \(Self.quote(directory.path)) \(Self.quote(event)) >/dev/null 2>&1 || :"
        // Codex Stop expects JSON on successful stdout. A neutral object preserves
        // its response flow even when the private notification helper fails.
        // https://learn.chatgpt.com/docs/hooks#stop
        return agent == .codex ? invocation + "; printf '%s\\n' '{}'" : invocation
    }

    func handler(for event: String) -> [String: Any] {
        ["type": "command", "command": command(for: event), "timeout": 2]
    }

    /// Exact command identity, not a substring/name match. User-added sibling handlers survive.
    private func owns(_ handler: [String: Any], event: String) -> Bool {
        guard handler["type"] as? String == "command", let command = handler["command"] as? String else { return false }
        return (1...helperVersion).contains { version in
            command == HookInstallation(agent: agent, directory: directory, helperVersion: version).command(for: event)
        }
    }

    private func checkedData(_ url: URL) throws -> Data? {
        let fm = FileManager.default
        try rejectLinks(url)
        guard fm.fileExists(atPath: url.path) else { return nil }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maximumConfigBytes else {
            throw HookInstallationError.invalid("Configuration is not a regular file or is too large: \(url.lastPathComponent)")
        }
        return try Data(contentsOf: url)
    }

    /// Refuse symlinks rather than replacing their target or silently breaking a user's setup.
    func rejectLinks(_ url: URL) throws {
        var current = url
        while current.path != "/" {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: current.path),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                // macOS exposes these root-owned system aliases even for resolved temp URLs.
                let systemAlias = ["/var": "private/var", "/tmp": "private/tmp"]
                let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)
                if systemAlias[current.path] != destination || systemAlias[current.path] == nil {
                    throw HookInstallationError.invalid("Symbolic links cannot be updated automatically: \(current.path)")
                }
            }
            current.deleteLastPathComponent()
        }
    }

    private func object(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallationError.invalid("Configuration JSON must be an object.")
        }
        return object
    }

    private func hooks(_ object: [String: Any]) throws -> [String: Any] {
        guard let value = object["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else {
            throw HookInstallationError.invalid("The existing hooks format cannot be preserved.")
        }
        return hooks
    }

    private func groups(_ hooks: [String: Any], event: String) throws -> [[String: Any]] {
        guard let value = hooks[event] else { return [] }
        guard let groups = value as? [[String: Any]], groups.allSatisfy({ $0["hooks"] is [[String: Any]] }) else {
            throw HookInstallationError.invalid("The existing \(event) hook format cannot be preserved.")
        }
        return groups
    }

    func inspect() -> HookInstallationState {
        do {
            let data = try checkedData(file)
            let object = try object(data)
            let hooks = try hooks(object)
            var count = 0
            for event in managedEvents {
                var eventCount = 0
                for group in try groups(hooks, event: event) {
                    for entry in group["hooks"] as! [[String: Any]] where owns(entry, event: event) {
                        if entry["command"] as? String != command(for: event) { return .updateAvailable }
                        guard NSDictionary(dictionary: entry).isEqual(to: handler(for: event)),
                              group["matcher"] == nil else {
                            return .failure("SpaceWidget hooks were modified. Remove and reinstall them.")
                        }
                        count += 1
                        eventCount += 1
                    }
                }
                if eventCount > 1 { return .failure("Duplicate SpaceWidget hooks were found.") }
            }
            if count == 0 { return .installable }
            guard count == managedEvents.count else { return .failure("Some hooks are missing or duplicated.") }
            try rejectLinks(helper)
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                return .failure("The hook helper is missing. Reinstall the hooks.")
            }
            guard let recordedHash = try checkedData(helperHash),
                  recordedHash == Data(Self.digest(try Data(contentsOf: helper)).utf8) else {
                return .failure("The hook helper has been modified.")
            }
            if object["disableAllHooks"] as? Bool == true { return .failure("All hooks are disabled in the configuration.") }
            // An execution receipt does NOT prove approval: Codex also offers a bypass flag.
            // Until a documented read-only exact-hash trust observation is available, fail closed.
            if agent == .codex { return .pendingTrust }
            guard let data, let recorded = try checkedData(receipt),
                  let receipt = try? JSONDecoder().decode(HookInstallationReceipt.self, from: recorded),
                  receipt.configurationDigest == Self.digest(data),
                  receipt.helperDigest == Self.digest(try Data(contentsOf: helper)) else { return .awaitingExecution }
            return .connected
        } catch { return .failure(error.localizedDescription) }
    }

    /// Helper bytes come from the running native executable, or a temporary test fixture.
    /// Returns a backup URL only if an existing configuration actually changed.
    @discardableResult
    func install(helperBytes: Data, beforeCommit: () throws -> Void = {}) throws -> URL? {
        try mutate(install: true, helperBytes: helperBytes, beforeCommit: beforeCommit)
    }

    @discardableResult
    func uninstall(beforeCommit: () throws -> Void = {}) throws -> URL? {
        try mutate(install: false, helperBytes: nil, beforeCommit: beforeCommit)
    }

    private func mutate(install: Bool, helperBytes: Data?, beforeCommit: () throws -> Void) throws -> URL? {
        let fm = FileManager.default
        try rejectLinks(directory)
        // Uninstall of an absent config is a true no-op, including no directory creation.
        if !install && !fm.fileExists(atPath: file.path) { return nil }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Lock the configuration directory without creating a lock in user configuration.
        let lock = open(directory.path, O_RDONLY | O_NOFOLLOW)
        guard lock >= 0 else { throw HookInstallationError.invalid("Cannot open the configuration folder.") }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw HookInstallationError.busy }
        let original = try checkedData(file)
        var document = try object(original)
        var hookMap = try hooks(document)
        var changed = false
        var hadCurrentHook = false
        for event in managedEvents {
            var remaining: [[String: Any]] = []
            var ownedCount = 0
            for var group in try groups(hookMap, event: event) {
                let entries = group["hooks"] as! [[String: Any]]
                hadCurrentHook = hadCurrentHook || entries.contains { $0["command"] as? String == command(for: event) }
                let kept = entries.filter { !owns($0, event: event) }
                ownedCount += entries.count - kept.count
                if entries.count == kept.count { remaining.append(group) }
                else if !kept.isEmpty { group["hooks"] = kept; remaining.append(group) }
            }
            if install {
                remaining.append(["hooks": [handler(for: event)]])
            }
            if ownedCount > 0 || install {
                changed = true
                if remaining.isEmpty { hookMap.removeValue(forKey: event) }
                else { hookMap[event] = remaining }
            }
        }
        guard changed else { return nil }
        if hookMap.isEmpty { document.removeValue(forKey: "hooks") }
        else { document["hooks"] = hookMap }
        let proposed = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let semanticallyEqual = try original.map { NSDictionary(dictionary: try object($0)).isEqual(to: document) } ?? false
        // Prepare helper before adding a reference. Never overwrite an unrecognized support directory.
        try rejectLinks(support)
        let marker = support.appendingPathComponent("owner")
        let existingSupport = fm.fileExists(atPath: support.path)
        if existingSupport {
            guard try checkedData(marker) == Data("SpaceWidget hook helper v1\n".utf8) else {
                throw HookInstallationError.invalid("The helper location is already in use: \(support.path)")
            }
        } else if install {
            try fm.createDirectory(at: support, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("SpaceWidget hook helper v1\n".utf8).write(to: marker, options: .atomic)
        }
        if install, let helperBytes {
            guard !helperBytes.isEmpty else { throw HookInstallationError.invalid("The helper executable is empty.") }
            try rejectLinks(helper)
            if !fm.fileExists(atPath: helper.path) {
                let expectedHash = try checkedData(helperHash)
                let proposedHash = Data(Self.digest(helperBytes).utf8)
                if let expectedHash {
                    guard expectedHash == proposedHash else {
                        throw HookInstallationError.invalid("The helper cannot be restored with different contents. A new hook version is required.")
                    }
                } else {
                    var verifiedUpgrade = false
                    if helperVersion > 1 && existingSupport && !hadCurrentHook {
                        // Verify the latest installed predecessor. Never rewrite bytes
                        // behind an approved command or bypass a damaged newer helper.
                        for version in (1..<helperVersion).reversed() {
                            let legacy = HookInstallation(agent: agent, directory: directory, helperVersion: version)
                            try rejectLinks(legacy.helper)
                            let recorded = try checkedData(legacy.helperHash)
                            guard fm.fileExists(atPath: legacy.helper.path) || recorded != nil else { continue }
                            if let recorded, let bytes = try? Data(contentsOf: legacy.helper) {
                                verifiedUpgrade = recorded == Data(Self.digest(bytes).utf8)
                            }
                            break
                        }
                    }
                    guard (!existingSupport && !hadCurrentHook) || verifiedUpgrade else {
                        throw HookInstallationError.invalid("The saved helper digest is missing. Its integrity cannot be verified.")
                    }
                    // Record identity before publication so interrupted first installs
                    // can recover only the same executable behind the approved command.
                    try atomicWrite(proposedHash, to: helperHash, mode: 0o600)
                }
                try atomicWrite(helperBytes, to: helper, mode: 0o700)
            } else {
                guard try checkedData(helperHash) == Data(Self.digest(try Data(contentsOf: helper)).utf8) else {
                    throw HookInstallationError.invalid("The hook helper integrity check failed.")
                }
            }
            // Never replace code behind an already trusted command. A future helper upgrade
            // must use a new versioned path and therefore require a new Codex approval.
        }
        if semanticallyEqual { return nil }
        try beforeCommit()
        guard try checkedData(file) == original else { throw HookInstallationError.changed }
        var backup: URL?
        if let original {
            let destination = directory.appendingPathComponent("\(file.lastPathComponent).spacewidget-backup-\(UUID().uuidString)")
            try atomicWrite(original, to: destination, mode: 0o600)
            backup = destination
        }
        // Old execution evidence must not reconnect an uninstall/reinstall of identical JSON.
        try rejectLinks(receipt)
        if fm.fileExists(atPath: receipt.path) { try fm.removeItem(at: receipt) }
        let mode = (try? fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        try atomicWrite(proposed, to: file, mode: mode)
        // Keep the inert helper and backups: in-flight hooks can still finish and no directory
        // containing user additions is recursively removed. No config references remain on uninstall.
        return backup
    }

    /// Same-directory temp + fsync + rename: readers see the complete old or new JSON.
    // Shared with the local event spool so metadata is private before atomic publication.
    func atomicWrite(_ data: Data, to target: URL, mode: Int) throws {
        try rejectLinks(target)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".spacewidget-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(mode))
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        guard fchmod(fd, mode_t(mode)) == 0, fsync(fd) == 0,
              rename(temporary.path, target.path) == 0 else { throw POSIXError(.EIO) }
        let parent = open(target.deletingLastPathComponent().path, O_RDONLY | O_NOFOLLOW)
        if parent >= 0 { _ = fsync(parent); close(parent) }
    }
}
