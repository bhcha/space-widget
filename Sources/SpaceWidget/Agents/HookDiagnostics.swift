import Foundation
import Darwin

/// Metadata only: no hook payload, prompt, transcript, full cwd or window title.
/// Separate from swLog: a short-lived helper must never truncate the app's log.
struct HookDiagnostics {
    struct Record: Codable {
        let schema: Int
        let time: Double
        let pid: Int32
        let stage: String
        let fields: [String: String]
    }

    let write: (Record) -> Void
    static let disabled = HookDiagnostics { _ in }
    static let live: HookDiagnostics = {
        // Tests opt in with an isolated sink; ordinary fixture events must not pollute evidence.
        guard !ProcessInfo.processInfo.processName.contains("xctest") else { return .disabled }
        return file(at: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/space-dock/agent-hooks.jsonl"))
    }()

    func emit(_ stage: String, event: AgentHookEvent? = nil, fields: [String: String] = [:]) {
        var metadata = event?.diagnosticFields ?? [:]
        metadata.merge(fields) { _, new in new }
        write(Record(schema: 1, time: Date().timeIntervalSince1970, pid: getpid(), stage: stage,
                     fields: metadata.mapValues { String($0.prefix(2048)) }))
    }

    /// Two bounded files, shared by app/helper processes, survive restarts. Lock waits
    /// are capped at 20ms so diagnostic contention cannot hold up a coding agent.
    static func file(at url: URL, maximumBytes: Int = 2 * 1024 * 1024) -> HookDiagnostics {
        HookDiagnostics { record in
            do {
                let fm = FileManager.default
                let directory = url.deletingLastPathComponent()
                let checker = HookInstallation(agent: .codex, directory: directory)
                try checker.rejectLinks(directory)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                let lock = open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
                guard lock >= 0 else { return }
                defer { close(lock) }
                var locked = false
                for attempt in 0..<11 {
                    if flock(lock, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
                    if attempt < 10 { usleep(2_000) }
                }
                guard locked else { return }
                defer { flock(lock, LOCK_UN) }
                try checker.rejectLinks(url)
                let backup = URL(fileURLWithPath: url.path + ".1")
                try checker.rejectLinks(backup)
                var data = try JSONEncoder().encode(record)
                data.append(0x0a)
                guard data.count <= maximumBytes else { return }
                if let attributes = try? fm.attributesOfItem(atPath: url.path) {
                    guard attributes[.type] as? FileAttributeType == .typeRegular else { return }
                    if (attributes[.size] as? NSNumber)?.intValue ?? 0 > maximumBytes - data.count {
                        guard rename(url.path, backup.path) == 0 else { return }
                    }
                }
                let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
                guard fd >= 0 else { return }
                defer { close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return }
                _ = fchmod(fd, 0o600)
                data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { break }
                        offset += count
                    }
                }
            } catch { /* Best effort; never log arbitrary error strings containing user paths. */ }
        }
    }
}

extension AgentHookEvent {
    /// Event identity survives a spool drain/restart; request identity joins prompt and Stop.
    var traceID: String {
        HookInstallation.digest(Data("\(duplicateKey):\(received.timeIntervalSinceReferenceDate)".utf8))
    }
    var diagnosticFields: [String: String] {
        var fields = ["trace": traceID, "session": sessionKey, "agent": agentID, "source": source,
                      "kind": kind, "project": project ?? "unknown", "received": String(received.timeIntervalSince1970),
                      "turn_present": String(turn != nil)]
        if let turn { fields["request"] = HookInstallation.digest(Data("\(sessionKey):\(turn)".utf8)) }
        fields["origin_uuid"] = origin?.spaceUUID
        fields["origin_display"] = origin?.displayID
        fields["origin_capture_policy"] = originCapturePolicy
        fields["application"] = application?.bundleID
        fields["application_pid"] = application.map { String($0.processID) }
        fields["context_match"] = contextMatch
        fields["context_trace"] = contextTrace
        fields["start_source"] = startSource
        return fields
    }
}
