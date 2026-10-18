import Foundation
import Combine

struct AgentCompletionNotice: Identifiable, Equatable {
    let id = UUID()
    let event: AgentHookEvent
    let space: String?
    let isTest: Bool
    var origin: AgentOrigin? = nil
    var navigationIssue: String? = nil
    var title: String { event.project ?? "Unknown project" }
    var status: String { "done" }
    var destination: AgentOrigin? { isTest || navigationIssue != nil ? nil : origin }
    var actionTitle: String { space.map { "Go to \($0)" } ?? "Go to Space" }
    var detail: String {
        [event.agent?.name ?? event.agentID, event.application?.name,
         space ?? "Unknown Space"].compactMap { $0 }.joined(separator: " · ")
    }
    var diagnosticFields: [String: String] {
        ["notice": id.uuidString, "title": title, "space_label": space ?? "unknown",
         "destination_uuid": destination?.spaceUUID ?? "none",
         "destination_display": destination?.displayID ?? "none", "preview": String(isTest)]
    }
}

@MainActor
final class AgentNotificationModel: ObservableObject {
    static let shared = AgentNotificationModel()
    @Published var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: "agentNotifications")
            if !notificationsEnabled { cancelPresentation() }
        }
    }
    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "agentNotificationSound") } }
    @Published private(set) var latest: AgentCompletionNotice?
    @Published private(set) var pendingCount = 0
    @Published private(set) var deliveryIssue: String?
    private let defaults: UserDefaults
    private let diagnostics: HookDiagnostics
    private let originNavigation: AgentOriginNavigation
    private let present: @MainActor (AgentCompletionNotice) -> Void
    private let playSound: @MainActor () -> Void
    private let cancelPresentation: @MainActor () -> Void
    var onSessionStart: (AgentHookEvent) -> Void = { _ in }
    private var installations: [HookInstallation] = []
    private var polling = false
    private let startedAt: Date
    private var timer: Timer?

    init(defaults: UserDefaults = .standard, startedAt: Date = Date(),
         installations: [HookInstallation] = [], originNavigation: AgentOriginNavigation? = nil,
         diagnostics: HookDiagnostics = .live,
         present: @escaping @MainActor (AgentCompletionNotice) -> Void = { AgentToastPresenter.shared.show($0) },
         cancelPresentation: @escaping @MainActor () -> Void = { AgentToastPresenter.shared.clear() },
         playSound: @escaping @MainActor () -> Void = { AgentToastPresenter.playSound() }) {
        self.defaults = defaults
        self.diagnostics = diagnostics
        self.originNavigation = originNavigation ?? .shared
        self.startedAt = startedAt
        self.installations = installations
        self.present = present
        self.playSound = playSound
        self.cancelPresentation = cancelPresentation
        notificationsEnabled = defaults.object(forKey: "agentNotifications") as? Bool ?? true
        soundEnabled = defaults.object(forKey: "agentNotificationSound") as? Bool ?? false
    }

    func start() {
        guard timer == nil else { return }
        // No version probes or hook installation. Honor the same custom directories as detection.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        installations = LocalAgent.allCases.map { agent in
            let custom = environment[agent == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"]
            let directory = custom.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
                ?? home.appendingPathComponent(agent == .codex ? ".codex" : ".claude")
            return HookInstallation(agent: agent, directory: directory)
        }
        diagnostics.emit("app.started", fields: ["helper_version": String(HookInstallation.currentHelperVersion), "notifications_enabled": String(notificationsEnabled)])
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }

    func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        let targets = installations
        let cutoff = startedAt
        let diagnostics = self.diagnostics
        let result = await Task.detached(priority: .utility) {
            var events: [AgentHookEvent] = []
            var pending = 0
            var failed = false
            for installation in targets {
                let transport = HookEventTransport(installation: installation)
                guard FileManager.default.fileExists(atPath: transport.file.path) else { continue }
                do {
                    events += try transport.drain(since: cutoff)
                    pending += try transport.pendingCount(before: cutoff)
                } catch {
                    failed = true
                    let error = error as NSError
                    diagnostics.emit("app.poll_failed", fields: ["agent": installation.agent.rawValue,
                        "error_domain": error.domain, "error_code": String(error.code)])
                }
            }
            return (events, pending, failed)
        }.value
        pendingCount = result.1
        deliveryIssue = result.2 ? "Cannot read local notifications. The next check will retry." : nil
        for event in result.0 { receive(event) }
    }

    /// Earlier-process events require an explicit runtime choice; no automatic replay policy
    /// was approved. The bounded spool is not a promise of durable offline notification storage.
    func resolvePending(show: Bool) async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        let targets = installations
        let result = await Task.detached(priority: .utility) {
            var events: [AgentHookEvent] = []
            var failed = false
            for installation in targets {
                let transport = HookEventTransport(installation: installation)
                guard FileManager.default.fileExists(atPath: transport.file.path) else { continue }
                do { events += try transport.drain() } catch { failed = true }
            }
            return (events, failed)
        }.value
        pendingCount = 0
        deliveryIssue = result.1 ? "Some pending notifications could not be processed." : nil
        for event in result.0 where show || event.received >= startedAt { receive(event) }
    }

    func receive(_ event: AgentHookEvent) {
        diagnostics.emit("app.received", event: event, fields: ["enabled": String(notificationsEnabled)])
        guard event.agent != nil else { return }
        if event.kind == "SessionStart" { onSessionStart(event); return }
        guard event.kind == "Stop", notificationsEnabled else { return }
        let origin = originNavigation.origin(for: event)
        let result: String
        let issue: String?
        if origin != nil {
            result = "resolved"
            issue = nil
        } else if event.origin == nil {
            result = "missing_capture"
            issue = "Could not determine the Space where this task started."
        } else if event.originCapturePolicy != AgentSpaceCapture.policy {
            result = "unverified_capture"
            issue = "This task's Space could not be verified. Update hooks and start a new request."
        } else {
            result = "space_unavailable"
            issue = "The Space where this task started is no longer available."
        }
        diagnostics.emit("app.destination", event: event, fields: ["result": result])
        deliver(AgentCompletionNotice(event: event, space: origin.flatMap { originNavigation.label(for: $0) },
            isTest: false, origin: origin, navigationIssue: issue))
    }

    @discardableResult
    func testNotification(agent: LocalAgent = .codex) -> Bool {
        guard notificationsEnabled else { return false }
        let event = AgentHookEvent(agentID: agent.rawValue, source: "preview", session: "Preview",
                                   kind: "Stop", turn: nil, received: Date(), project: "space-widget")
        deliver(AgentCompletionNotice(event: event, space: nil, isTest: true))
        return true
    }

    private func deliver(_ notice: AgentCompletionNotice) {
        diagnostics.emit("app.delivered", event: notice.event, fields: notice.diagnosticFields)
        latest = notice
        present(notice)
        if soundEnabled { playSound() }
    }
}
