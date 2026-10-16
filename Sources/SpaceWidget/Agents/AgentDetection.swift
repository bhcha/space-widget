import Foundation
import AppKit

/// Detection is deliberately separate from installation and connection verification.
/// A supported runtime is never evidence of an installed, trusted, working hook.
enum LocalAgent: String, CaseIterable, Identifiable {
    case codex, claude
    var id: String { rawValue }
    var name: String { self == .codex ? "Codex" : "Claude Code" }
    var provider: String { self == .codex ? "OpenAI" : "Anthropic" }
    var bundleID: String { self == .codex ? "com.openai.codex" : "com.anthropic.claudefordesktop" }
}

enum HookCapability: Equatable {
    case supported, unsupported(String), unknown(String)
    var label: String {
        switch self {
        case .supported: return "Hooks supported · Connection not verified"
        case .unsupported(let reason): return "Unsupported · \(reason)"
        case .unknown(let reason): return "Support unverified · \(reason)"
        }
    }
}

struct AgentRuntime: Identifiable, Equatable {
    enum Scope: String { case cli = "CLI", desktop = "Desktop" }
    let scope: Scope
    let location: URL
    let version: String?
    let capability: HookCapability
    var id: String { "\(scope.rawValue):\(location.path)" }
}

struct AgentDetection: Identifiable {
    let agent: LocalAgent
    let configurationDirectory: URL
    let runtimes: [AgentRuntime]
    let issues: [String]
    var id: LocalAgent { agent }
    /// Installing local hook configuration is separate from proving runtime capability.
    /// A verified desktop bundle may prepare its local Code integration even without
    /// a separate CLI. Only a real callback can establish a working connection.
    var allowsHookSetup: Bool {
        issues.isEmpty && runtimes.contains {
            if $0.capability == .supported { return true }
            if $0.scope == .desktop, case .unknown = $0.capability { return true }
            return false
        }
    }
    var readiness: String {
        if runtimes.contains(where: { $0.capability == .supported }) {
            return "Ready to install · Approval and connection not verified"
        }
        if runtimes.isEmpty { return issues.isEmpty ? "Not found" : "Scan failed" }
        if allowsHookSetup {
            return agent == .claude
                ? "Desktop detected · Local Code hooks need verification"
                : "Desktop detected · Hooks need approval and verification"
        }
        return "Hook support needs verification"
    }
}

struct AgentProbeResult {
    let status: Int32
    let output: String
}

enum AgentProbeError: Error { case timedOut, excessiveOutput }

/// No shell evaluation, login shell, interactive session, or agent execution.
/// Output and time are bounded; isolated HOME/config/cwd prevent config side effects.
struct AgentCommandProbe {
    var timeout: TimeInterval = 3
    var outputLimit = 32_768
    var inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"

    func run(_ executable: URL, _ arguments: [String]) throws -> AgentProbeResult {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = root
        // Retain PATH for node-based distributions, but never credentials or agent settings.
        process.environment = ["HOME": root.path, "CODEX_HOME": root.path,
            "CLAUDE_CONFIG_DIR": root.path, "XDG_CONFIG_HOME": root.path,
            // nvm's codex launcher uses /usr/bin/env node. Finder does not load nvm,
            // so give a detected executable access to its sibling runtime explicitly.
            "PATH": ([executable.deletingLastPathComponent().path]
                + inheritedPath.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
                + ["/usr/bin", "/bin"]).joined(separator: ":"),
            "NO_COLOR": "1", "TERM": "dumb", "DISABLE_AUTOUPDATER": "1"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let reader = pipe.fileHandleForReading
        let flags = fcntl(reader.fileDescriptor, F_GETFL)
        _ = fcntl(reader.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        defer { try? reader.close(); try? pipe.fileHandleForWriting.close() }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        var output = Data()
        var overflow = false
        func drain() {
            var buffer = [UInt8](repeating: 0, count: 4096)
            // Bound each drain too: a noisy producer must not defeat the deadline.
            for _ in 0..<16 {
                let count = read(reader.fileDescriptor, &buffer, buffer.count)
                if count <= 0 { break }
                if count > outputLimit - output.count { overflow = true; break }
                output.append(contentsOf: buffer.prefix(count))
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline && !overflow {
            drain()
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw overflow ? AgentProbeError.excessiveOutput : AgentProbeError.timedOut
        }
        process.waitUntilExit()
        drain()
        if overflow { throw AgentProbeError.excessiveOutput }
        return AgentProbeResult(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
    }
}

struct AgentDetector {
    var home: URL
    var environment: [String: String]
    var executableDirectories: [URL]
    var applicationDirectories: [URL]
    var registeredApplication: (String) -> URL?
    var probe: (URL, [String]) throws -> AgentProbeResult

    /// Finder does not source shell startup files. Inspect nvm's bounded local
    /// version directory in addition to PATH, without evaluating any shell code.
    static func executableSearchDirectories(home: URL, environment: [String: String]) -> [URL] {
        var paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        paths += [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        if let bin = environment["NVM_BIN"], bin.hasPrefix("/") { paths.append(bin) }
        let nvm = environment["NVM_DIR"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appendingPathComponent(".nvm")
        let versions = nvm.appendingPathComponent("versions/node")
        let entries = (try? FileManager.default.contentsOfDirectory(at: versions,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let candidates = entries.filter {
            $0.lastPathComponent.range(of: #"^v\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        paths += candidates.prefix(32).map {
            versions.appendingPathComponent($0.lastPathComponent).appendingPathComponent("bin").path
        }
        var seen = Set<String>()
        return paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }.map { URL(fileURLWithPath: $0) }
    }

    static func system() -> AgentDetector {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Resolve Launch Services on the main thread, then probe off the UI thread.
        let registered = Dictionary(uniqueKeysWithValues: LocalAgent.allCases.compactMap { agent in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: agent.bundleID).map { (agent.bundleID, $0) }
        })
        return AgentDetector(home: home, environment: ProcessInfo.processInfo.environment,
            executableDirectories: executableSearchDirectories(home: home, environment: ProcessInfo.processInfo.environment),
            applicationDirectories: [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")],
            registeredApplication: { registered[$0] }, probe: { try AgentCommandProbe().run($0, $1) })
    }

    func scan() -> [AgentDetection] { LocalAgent.allCases.map(detect) }

    func detect(_ agent: LocalAgent) -> AgentDetection {
        let fm = FileManager.default
        var runtimes: [AgentRuntime] = []
        var issues: [String] = []
        // Ignore relative PATH entries: detection must not execute a workspace's namesake file.
        var seen = Set<String>()
        for directory in executableDirectories {
            let executable = directory.appendingPathComponent(agent.rawValue)
            guard fm.isExecutableFile(atPath: executable.path),
                  seen.insert(executable.resolvingSymlinksInPath().path).inserted else { continue }
            runtimes.append(runtime(agent, scope: .cli, location: executable, executable: executable, appVersion: nil))
        }
        var apps: [URL] = []
        if let registered = registeredApplication(agent.bundleID) { apps.append(registered) }
        for directory in applicationDirectories where fm.fileExists(atPath: directory.path) {
            do {
                let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                apps += entries.filter { $0.pathExtension == "app" }
            } catch { issues.append("Cannot read application folder: \(directory.path)") }
        }
        seen.removeAll()
        for app in apps where seen.insert(app.resolvingSymlinksInPath().path).inserted {
            let plist = app.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plist),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == agent.bundleID else { continue }
            let version = info["CFBundleShortVersionString"] as? String
            // App version != embedded CLI version. Never transfer CLI support to desktop.
            runtimes.append(AgentRuntime(scope: .desktop, location: app, version: version,
                capability: .unknown(agent == .claude
                    ? "Claude detected · Regular Chat is not supported. Check the local Code runtime."
                    : "App and CLI versions are separate. Check the app's hook support.")))
        }
        let key = agent == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
        let override = environment[key]
        let config: URL
        if let override, override.hasPrefix("/") {
            config = URL(fileURLWithPath: override)
        } else {
            config = home.appendingPathComponent(agent == .codex ? ".codex" : ".claude")
            if override != nil { issues.append("\(key) must be an absolute path. Check your session configuration.") }
        }
        return AgentDetection(agent: agent, configurationDirectory: config, runtimes: runtimes, issues: issues)
    }

    private func runtime(_ agent: LocalAgent, scope: AgentRuntime.Scope, location: URL,
                         executable: URL, appVersion: String?) -> AgentRuntime {
        var version: String?
        let capability: HookCapability
        do {
            let result = try probe(executable, ["--version"])
            guard result.status == 0 else { throw DetectionError.probeFailed }
            let pattern = agent == .codex ? #"^codex-cli (\d+)\.(\d+)\.(\d+)$"# : #"^(\d+)\.(\d+)\.(\d+) \(Claude Code\)$"#
            let raw = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.range(of: pattern, options: .regularExpression) != nil else {
                throw DetectionError.unrecognizedVersion
            }
            version = raw
            if agent == .claude {
                let parts = raw.split(separator: " ")[0].split(separator: ".").compactMap { Int($0) }
                // Official changelog: 1.0.41 separates SubagentStop; 1.0.62 adds SessionStart.
                // https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md
                capability = parts.lexicographicallyPrecedes([1, 0, 62])
                    ? .unsupported("Version 1.0.62 or later is required for SessionStart and separate Stop hooks") : .supported
            } else {
                let features = try probe(executable, ["features", "list"])
                guard features.status == 0 else { throw DetectionError.probeFailed }
                let supported = features.output.split(separator: "\n").contains { line in
                    let fields = line.split(whereSeparator: { $0.isWhitespace })
                    return fields.count >= 3 && ["hooks", "codex_hooks"].contains(String(fields[0]))
                        && ["true", "false"].contains(String(fields.last!))
                }
                // Isolated config probes binary capability only, not user's effective settings/trust.
                capability = supported ? .supported : .unknown("This CLI did not report hook support")
            }
        } catch {
            capability = .unknown("Version or capability check failed: \(error)")
        }
        return AgentRuntime(scope: scope, location: location, version: version ?? appVersion, capability: capability)
    }
    private enum DetectionError: Error { case probeFailed, unrecognizedVersion }
}
