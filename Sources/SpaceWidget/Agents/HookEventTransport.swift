import Foundation
import Darwin

/// Only allowlisted metadata crosses the helper/app boundary. No paths to transcripts,
/// prompt text, full cwd, or completion-time window information are retained.
struct AgentHookEvent: Codable, Equatable {
    let agentID: String
    let source: String
    let session: String
    let kind: String
    let turn: String?
    let received: Date
    var project: String? = nil
    var origin: AgentOrigin? = nil
    var application: AgentApplicationTarget? = nil
    var contextMatch: String? = nil
    var contextTrace: String? = nil
    var startSource: String? = nil
    // Absent in legacy spools. Only the receiver sets this after its own capture;
    // provider payloads cannot assert that an old/guessed origin is verified.
    var originCapturePolicy: String? = nil

    var agent: LocalAgent? { LocalAgent(rawValue: agentID) }
    var sessionKey: String { HookInstallation.digest(Data("\(source)\u{0}\(session)".utf8)) }
    var duplicateKey: String {
        HookInstallation.digest(Data("\(sessionKey)\u{0}\(kind)\u{0}\(turn ?? "")".utf8))
    }

    static func parse(_ object: [String: Any], installation: HookInstallation,
                      expectedKind: String, now: Date = Date()) -> AgentHookEvent? {
        func identifier(_ value: Any?) -> String? {
            guard let value = value as? String, !value.isEmpty, value.utf8.count <= 512,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return value
        }
        guard HookInstallation.events.contains(expectedKind),
              object["hook_event_name"] as? String == expectedKind,
              let session = identifier(object["session_id"]),
              object["stop_hook_active"] as? Bool != true,
              object["agent_id"] == nil, object["subagent_id"] == nil else { return nil }
        // Claude's documented per-prompt ID is metadata, not prompt content.
        // agent_type alone also appears for a primary `claude --agent` session;
        // only agent_id/subagent_id establishes a child here.
        // https://code.claude.com/docs/en/hooks#common-input-fields
        let identityField = installation.agent == .claude && object["prompt_id"] != nil ? "prompt_id" : "turn_id"
        let turn = identifier(object[identityField])
        if object[identityField] != nil && turn == nil { return nil }
        let source = object["source"] as? String
        let startSource = expectedKind == "SessionStart" && ["startup", "resume", "clear", "compact", "fork"].contains(source ?? "") ? source : nil
        return AgentHookEvent(agentID: installation.agent.rawValue,
            source: HookInstallation.digest(Data("\(installation.agent.rawValue):\(installation.directory.standardizedFileURL.path)".utf8)),
            session: session, kind: expectedKind, turn: turn, received: now,
            project: AgentProjectName.resolve(cwd: object["cwd"] as? String), startSource: startSource)
    }
}

/// A small locked spool, shared by helper processes and the app. Nonblocking lock
/// contention drops delivery, never stalls the agent. Dedup state survives consumption/restart.
struct HookEventTransport {
    static let maximumEvents = 64
    static let maximumSeen = 512
    static let maximumBytes = 262_144
    let installation: HookInstallation
    var diagnostics: HookDiagnostics = .live
    var file: URL { installation.support.appendingPathComponent("events-v1.json") }
    private struct Seen: Codable { let key: String; let at: Date; let hasTurn: Bool }
    private struct Context: Codable {
        let key: String
        let kind: String
        let turn: String?
        let origin: AgentOrigin?
        let application: AgentApplicationTarget?
        let project: String?
        let at: Date
        var trace: String? = nil
        var originCapturePolicy: String? = nil
    }
    private struct State: Codable {
        var events: [AgentHookEvent] = []
        var seen: [Seen] = []
        // Optional for backwards-compatible decoding of the v1 spool.
        var contexts: [Context]? = nil
    }

    @discardableResult
    func enqueue(_ event: AgentHookEvent) throws -> Bool {
        var queued = event
        let accepted = try transaction { state in
            // Providers without a turn ID only permit short-window retry suppression;
            // distinct later responses in the same session must still notify.
            if state.seen.contains(where: {
                $0.key == event.duplicateKey && (event.received.timeIntervalSince($0.at) < ($0.hasTurn ? 86_400 : 2))
            }) {
                diagnostics.emit("transport.duplicate", event: event)
                return false
            }
            state.seen.append(Seen(key: event.duplicateKey, at: event.received, hasTurn: event.turn != nil))
            state.seen = Array(state.seen.suffix(Self.maximumSeen))
            var event = event
            var contexts = (state.contexts ?? []).filter { event.received.timeIntervalSince($0.at) < 86_400 }
            if event.kind == "SessionStart" || event.kind == "UserPromptSubmit" {
                if event.kind == "SessionStart" {
                    // Codex emits SessionStart during mid-turn compaction. Keep exact
                    // request snapshots even if that hook sees a different foreground.
                    // Without turn IDs, only an explicit compact can preserve a prompt.
                    contexts.removeAll {
                        $0.key == event.sessionKey && ($0.kind == "SessionStart" || ($0.turn == nil && event.startSource != "compact"))
                    }
                } else {
                    contexts.removeAll { $0.key == event.sessionKey && $0.kind == event.kind && $0.turn == event.turn }
                }
                // An unknown new request explicitly replaces stale location information.
                contexts.append(Context(key: event.sessionKey, kind: event.kind, turn: event.turn,
                                        origin: event.origin, application: event.application,
                                        project: event.project, at: event.received, trace: event.traceID,
                                        originCapturePolicy: event.originCapturePolicy))
                diagnostics.emit("context.staged", event: event)
            } else if event.kind == "Stop" {
                let session = contexts.filter { $0.key == event.sessionKey && $0.at <= event.received }
                let prompts = session.filter { $0.kind == "UserPromptSubmit" }
                let exact = prompts.last(where: { $0.turn == event.turn })
                let withoutID = prompts.last.flatMap { $0.turn == nil || event.turn == nil ? $0 : nil }
                let context = exact ?? withoutID
                // A SessionStart can be a resume/background startup on another desktop.
                // It is not evidence of where this request was submitted (text2sql → SD).
                event.contextMatch = context == nil
                    ? (prompts.isEmpty && !session.isEmpty ? "session_start_rejected" : "no_prompt_match")
                    : (exact != nil && event.turn != nil ? "exact_turn" : "prompt_without_turn")
                event.contextTrace = context?.trace
                // Stop never captures the foreground Space; it uses the request's snapshot.
                event.origin = context?.origin
                event.originCapturePolicy = context?.originCapturePolicy
                event.application = context?.application
                event.project = event.project ?? context?.project
                diagnostics.emit("context.resolved", event: event, fields: [
                    "prompt_count": String(prompts.count),
                    "context_age_seconds": context.map { String(event.received.timeIntervalSince($0.at)) } ?? "none",
                    "rejected_session_uuid": context == nil ? (session.last(where: { $0.kind == "SessionStart" })?.origin?.spaceUUID ?? "none") : "none"
                ])
            }
            state.contexts = Array(contexts.suffix(128))
            state.events.append(event)
            state.events = Array(state.events.suffix(Self.maximumEvents))
            queued = event
            return true
        }
        if accepted { diagnostics.emit("transport.committed", event: queued) }
        return accepted
    }

    func drain(since: Date? = nil) throws -> [AgentHookEvent] {
        try transaction { state in
            let events = state.events.filter { since == nil || $0.received >= since! }
            state.events.removeAll { since == nil || $0.received >= since! }
            return events
        }
    }

    func pendingCount(before date: Date) throws -> Int {
        try transaction { $0.events.filter { $0.received < date }.count }
    }

    private func transaction<T>(_ body: (inout State) throws -> T) throws -> T {
        try installation.rejectLinks(installation.support)
        try installation.rejectLinks(file)
        let lock = installation.support.appendingPathComponent("events-v1.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw HookInstallationError.busy }
        defer { flock(descriptor, LOCK_UN) }
        var state = State()
        if FileManager.default.fileExists(atPath: file.path) {
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw POSIXError(.EACCES) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size <= Self.maximumBytes else { throw POSIXError(.EFBIG) }
            let bytes = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
            state = try JSONDecoder().decode(State.self, from: bytes)
            guard state.events.count <= Self.maximumEvents, state.seen.count <= Self.maximumSeen, (state.contexts?.count ?? 0) <= 128 else {
                throw POSIXError(.EFBIG)
            }
        }
        let result = try body(&state)
        let bytes = try JSONEncoder().encode(state)
        guard bytes.count <= Self.maximumBytes else { throw POSIXError(.EFBIG) }
        try installation.atomicWrite(bytes, to: file, mode: 0o600)
        return result
    }
}
