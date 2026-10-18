import AppKit
import ApplicationServices

/// Stable destination captured when the request starts, never at completion.
struct AgentOrigin: Codable, Equatable, Hashable {
    let displayID: String
    let spaceUUID: String
}

struct AgentOriginSnapshot {
    struct Space {
        let uuid: String
        let id: UInt64
        let ordinal: Int
        let displayID: String
        var label: String? = nil
        var origin: AgentOrigin { .init(displayID: displayID, spaceUUID: uuid) }
    }
    let permitted: Bool
    let spaces: [Space]

    func resolve(_ origin: AgentOrigin) -> Space? {
        // A desktop can migrate to another display when monitors reconnect.
        // Its UUID is the identity; a captured display ID is only historical metadata.
        // Ambiguous duplicate UUIDs still fail closed, even on the old display.
        let matches = spaces.filter { $0.uuid == origin.spaceUUID }
        return matches.count == 1 ? matches[0] : nil
    }
}

@MainActor
protocol AgentOriginBackend: AnyObject {
    func snapshot() -> AgentOriginSnapshot
    func currentSpace(on displayID: String) -> UInt64?
    func requestSwitch(to space: AgentOriginSnapshot.Space)
}

@MainActor
final class AgentOriginNavigation {
    static let shared = AgentOriginNavigation(backend: NativeAgentOriginBackend())
    private let backend: AgentOriginBackend
    private let log: (String) -> Void
    private let wait: (Duration) async -> Void
    private let diagnostics: HookDiagnostics
    private var navigating = false

    init(backend: AgentOriginBackend,
         log: @escaping (String) -> Void = { swLog("SPACERETURN", $0) },
         diagnostics: HookDiagnostics = .live,
         wait: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.backend = backend
        self.log = log
        self.wait = wait
        self.diagnostics = diagnostics
    }

    func navigate(to origin: AgentOrigin, event: AgentHookEvent? = nil, noticeID: UUID? = nil) async -> Bool {
        var fields = ["destination_uuid": origin.spaceUUID, "destination_display": origin.displayID,
                      "notice": noticeID?.uuidString ?? "none"]
        var outcome = "busy"
        let started = Date()
        defer {
            fields["outcome"] = outcome
            fields["elapsed_ms"] = String(Int(Date().timeIntervalSince(started) * 1000))
            diagnostics.emit("navigation.finished", event: event, fields: fields)
        }
        guard !navigating else { return false }
        navigating = true
        defer { navigating = false }
        let initial = backend.snapshot()
        fields["spaces"] = initial.spaces.map { "\($0.id):\($0.uuid):\($0.displayID):\($0.ordinal):\($0.label ?? "")" }.joined(separator: ";")
        fields["accessibility"] = String(initial.permitted)
        guard let target = initial.resolve(origin) else {
            outcome = "destination_unavailable"
            log("unavailable uuid=\(origin.spaceUUID) display=\(origin.displayID)")
            return false
        }
        fields["captured_display"] = origin.displayID
        fields["destination_display"] = target.displayID
        fields["display_rebound"] = String(target.displayID != origin.displayID)
        let current = backend.currentSpace(on: target.displayID)
        fields["target_id"] = String(target.id)
        fields["target_label"] = target.label ?? "Space \(target.ordinal)"
        fields["actual_id"] = current.map(String.init) ?? "none"
        fields["actual_uuid"] = initial.spaces.first { $0.id == current && $0.displayID == target.displayID }?.uuid ?? "none"
        diagnostics.emit("navigation.requested", event: event, fields: fields)
        log("requested uuid=\(origin.spaceUUID) target=\(target.id) current=\(current ?? 0) display=\(target.displayID)")
        if current == target.id { outcome = "already_there"; log("already on target=\(target.id)"); return true }
        guard initial.permitted else { outcome = "accessibility_denied"; log("accessibility unavailable"); return false }
        backend.requestSwitch(to: target)
        // Event posting and application activation are not evidence of arrival.
        // Require a stable destination, including the macOS 27 bounce interval.
        var consecutive = 0
        var previous = current
        for sample in 0..<40 {
            let snapshot = backend.snapshot()
            guard !Task.isCancelled,
                  let resolved = snapshot.resolve(origin), resolved.id == target.id,
                  resolved.displayID == target.displayID else {
                outcome = Task.isCancelled ? "cancelled" : "destination_changed"
                log("cancelled or destination disappeared")
                return false
            }
            let actual = backend.currentSpace(on: target.displayID)
            fields["actual_id"] = actual.map(String.init) ?? "none"
            fields["actual_uuid"] = snapshot.spaces.first { $0.id == actual && $0.displayID == target.displayID }?.uuid ?? "none"
            if actual != previous {
                fields["sample"] = String(sample)
                diagnostics.emit("navigation.observed", event: event, fields: fields)
                previous = actual
            }
            consecutive = actual == target.id ? consecutive + 1 : 0
            if consecutive >= 9 {
                outcome = "confirmed"
                log("confirmed uuid=\(origin.spaceUUID) current=\(target.id)")
                return true
            }
            await wait(.milliseconds(50))
        }
        outcome = "not_reached"
        log("not reached target=\(target.id) current=\(backend.currentSpace(on: target.displayID) ?? 0)")
        return false
    }

    func origin(for event: AgentHookEvent) -> AgentOrigin? {
        guard let origin = event.origin else { return nil }
        guard event.originCapturePolicy == AgentSpaceCapture.policy else {
            diagnostics.emit("destination.rejected", event: event, fields: ["reason": "unverified_capture"])
            return nil
        }
        let snapshot = backend.snapshot()
        let resolved = snapshot.resolve(origin)
        diagnostics.emit("destination.resolved", event: event, fields: [
            "captured_display": origin.displayID,
            "resolved_display": resolved?.displayID ?? "none",
            "resolved_id": resolved.map { String($0.id) } ?? "none",
            "uuid_matches": String(snapshot.spaces.filter { $0.uuid == origin.spaceUUID }.count),
            "live_spaces": snapshot.spaces.map { "\($0.id):\($0.uuid):\($0.displayID)" }.joined(separator: ";")
        ])
        return resolved?.origin
    }

    func label(for origin: AgentOrigin) -> String? {
        guard let space = backend.snapshot().resolve(origin) else { return nil }
        return "Space \(space.ordinal)"
    }

}

@MainActor
final class NativeAgentOriginBackend: AgentOriginBackend {
    func snapshot() -> AgentOriginSnapshot {
        .init(permitted: AXIsProcessTrusted(), spaces: AgentSpaceCapture.spaces())
    }
    func currentSpace(on displayID: String) -> UInt64? {
        let id = CGSManagedDisplayGetCurrentSpace(CGSMainConnectionID(), displayID as CFString)
        return id == 0 ? nil : id
    }
    func requestSwitch(to space: AgentOriginSnapshot.Space) {
        // The 100ms check in the shared switcher may precede an animation's
        // completion. Navigation independently verifies the eventual destination.
        SpaceSwitcher.switchTo(spaceID: space.id, ordinal: space.ordinal, displayID: space.displayID)
    }
}

/// Terminal shells can sit below a root-owned /usr/bin/login process. libproc
/// denies its BSD info to the user, even though KERN_PROC_PID exposes its parent.
enum AgentProcessAncestry {
    static func bsdParent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func kernelParent(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid else { return nil }
        return info.kp_eproc.e_ppid
    }

    static func parent(of pid: pid_t,
                       bsd: (pid_t) -> pid_t? = bsdParent,
                       kernel: (pid_t) -> pid_t? = kernelParent) -> pid_t? {
        guard pid > 1 else { return nil }
        return bsd(pid) ?? kernel(pid)
    }

    static func ancestors(from first: pid_t, parent: (pid_t) -> pid_t? = { parent(of: $0) }) -> [pid_t] {
        var result: [pid_t] = []
        var pid = first
        for _ in 0..<32 {
            guard pid > 1, !result.contains(pid) else { break }
            result.append(pid)
            guard let next = parent(pid) else { break }
            pid = next
        }
        return result
    }
}

/// Called synchronously in the hook helper at SessionStart/UserPromptSubmit, never Stop.
/// App-level foreground state cannot identify the terminal that emitted the hook.
/// Detached/ambiguous sessions stay unknown, even when their host is foreground.
enum AgentSpaceCapture {
    static let policy = "single_host_space_v1"
    static func spaces() -> [AgentOriginSnapshot.Space] {
        let liveDisplays = Set(NSScreen.screens.compactMap { displayIdentifier(for: $0) })
        var result: [AgentOriginSnapshot.Space] = []
        for display in (CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]]) ?? [] {
            guard let displayID = display["Display Identifier"] as? String, liveDisplays.contains(displayID) else { continue }
            var ordinal = 0
            for space in (display["Spaces"] as? [[String: Any]]) ?? [] {
                guard (space["type"] as? Int) == 0,
                      let id = (space["ManagedSpaceID"] as? UInt64) ?? (space["id64"] as? UInt64),
                      let uuid = space["uuid"] as? String, !uuid.isEmpty else { continue }
                ordinal += 1
                result.append(.init(uuid: uuid, id: id, ordinal: ordinal, displayID: displayID))
            }
        }
        return result
    }

    static func select(windowSpaces: [[AgentOrigin]]) -> AgentOrigin? {
        // A different terminal of the same app can be foreground. Every enumerated
        // host window must belong to the same single navigable Space; an unknown,
        // full-screen or All-Spaces window must not be hidden by a known window.
        let unique = Set(windowSpaces.compactMap { $0.count == 1 ? $0.first : nil })
        return unique.count == 1 && windowSpaces.allSatisfy({ $0.count == 1 }) ? unique.first : nil
    }

    static func capture() -> AgentOrigin? {
        // A remote shell/multiplexer may have no GUI ancestor; do not guess by cwd.
        capture(ancestors: AgentProcessAncestry.ancestors(from: getppid()))
    }

    static func capture(ancestors: [pid_t]) -> AgentOrigin? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        guard let owner = ancestors.first(where: { pid in apps.contains { $0.processIdentifier == pid } }) else { return nil }
        return capture(owner: owner)
    }

    static func capture(owner: pid_t) -> AgentOrigin? {
        inspect(owner: owner).origin
    }

    static func inspect(owner: pid_t) -> (origin: AgentOrigin?, fields: [String: String]) {
        let spaces = spaces()
        let records = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var windowIDs: [String] = []
        let memberships: [[AgentOrigin]] = records.compactMap { record in
            guard record[kCGWindowOwnerPID as String] as? pid_t == owner,
                  record[kCGWindowLayer as String] as? Int == 0 else { return nil }
            guard let wid = record[kCGWindowNumber as String] as? UInt32,
                  let ids = CGSCopySpacesForWindows(CGSMainConnectionID(), 0x7, [wid] as CFArray) as? [UInt64] else { return [] }
            windowIDs.append("\(wid):" + ids.map { id in "\(id)=\(spaces.first { $0.id == id }?.uuid ?? "unmapped")" }.joined(separator: ","))
            // Preserve ambiguity, including full-screen memberships we do not navigate to.
            guard ids.count == 1, let space = spaces.first(where: { $0.id == ids[0] }) else { return [] }
            return [space.origin]
        }
        var foreground: AgentOrigin?
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontmost == owner,
           let display = CGSCopyActiveMenuBarDisplayIdentifier(CGSMainConnectionID()) as String? {
            let current = CGSManagedDisplayGetCurrentSpace(CGSMainConnectionID(), display as CFString)
            foreground = spaces.first { $0.displayID == display && $0.id == current }?.origin
        }
        let selected = select(windowSpaces: memberships)
        let reason = selected == nil ? (memberships.isEmpty ? "no_host_windows" : "ambiguous_host_windows")
            : "single_host_space"
        return (selected, ["capture_reason": reason, "host_pid": String(owner),
                           "foreground_pid": frontmost.map(String.init) ?? "none",
                           "foreground_uuid": foreground?.spaceUUID ?? "none",
                           "window_spaces": windowIDs.joined(separator: ";"),
                           "window_count": String(memberships.count)])
    }
}
