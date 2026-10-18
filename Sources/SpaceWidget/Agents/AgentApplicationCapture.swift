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
    var diagnostics: [String: String] = [:]

    static func capture() -> AgentLaunchContext {
        capture(ancestors: AgentProcessAncestry.ancestors(from: getppid()),
            environment: ProcessInfo.processInfo.environment, applications: AgentApplicationCapture.running())
    }

    static func capture(ancestors: [pid_t], environment: [String: String],
                        applications: [AgentApplicationTarget],
                        inspect: (pid_t) -> (origin: AgentOrigin?, fields: [String: String]) = AgentSpaceCapture.inspect) -> AgentLaunchContext {
        let application = AgentApplicationCapture.resolve(ancestors: ancestors,
            environment: environment, applications: applications)
        // A detached shell can retain another terminal's environment after reattachment.
        // Keep that app name for display, but only real ancestry can authorize capture.
        let ancestor = application.flatMap { ancestors.contains($0.processID) ? $0 : nil }
        let capture = ancestor.map { inspect($0.processID) }
        var fields = capture?.fields ?? ["capture_reason": application == nil ? "no_host_application" : "unverified_host"]
        fields["ancestors"] = ancestors.map(String.init).joined(separator: ",")
        fields["host_match"] = application.map { _ in ancestor != nil ? "ancestor" : "environment" } ?? "none"
        return .init(origin: capture?.origin, application: application, diagnostics: fields)
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
        // An environment match is a display hint, not proof of ownership or location.
        // Never infer the host from the coding-agent provider or foreground app.
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
