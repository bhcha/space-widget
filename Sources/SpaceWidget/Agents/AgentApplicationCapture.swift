import AppKit

/// Automatically captured host identity, never a manually associated window.
struct AgentApplicationTarget: Codable, Equatable {
    let bundleID: String
    let processID: pid_t
    let name: String
}

struct AgentLaunchContext {
    var origin: AgentOrigin?
    var application: AgentApplicationTarget?

    static func capture() -> AgentLaunchContext {
        let ancestors = AgentProcessAncestry.ancestors(from: getppid())
        let application = AgentApplicationCapture.resolve(ancestors: ancestors,
            environment: ProcessInfo.processInfo.environment, applications: AgentApplicationCapture.running())
        return .init(origin: application.flatMap { AgentSpaceCapture.capture(owner: $0.processID) },
                     application: application)
    }
}

enum AgentApplicationCapture {
    static func running() -> [AgentApplicationTarget] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated,
                  let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return nil }
            return .init(bundleID: bundleID, processID: app.processIdentifier,
                         name: app.localizedName ?? bundleID)
        }
    }

    static func resolve(ancestors: [pid_t], environment: [String: String],
                        applications: [AgentApplicationTarget]) -> AgentApplicationTarget? {
        for pid in ancestors {
            if let app = applications.first(where: { $0.processID == pid }) { return app }
        }
        // PeonPing's terminal environment mapping also handles detached shell hosts.
        // Verify a running app; never infer the host from the coding-agent provider
        // or whatever happens to be foreground when a response completes.
        let terminals = ["ghostty": "com.mitchellh.ghostty", "iTerm.app": "com.googlecode.iterm2",
                         "Apple_Terminal": "com.apple.Terminal", "WarpTerminal": "dev.warp.Warp-Stable",
                         "WezTerm": "com.github.wez.wezterm", "zed": "dev.zed.Zed"]
        let bundle = environment["TERM_PROGRAM"].flatMap { terminals[$0] }
            ?? environment["__CFBundleIdentifier"]
        guard let bundle else { return nil }
        let matches = applications.filter { $0.bundleID == bundle }
        return matches.count == 1 ? matches[0] : nil
    }
}
