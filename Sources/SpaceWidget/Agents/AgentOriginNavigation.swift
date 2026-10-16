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
        var origin: AgentOrigin { .init(displayID: displayID, spaceUUID: uuid) }
    }
    let permitted: Bool
    let spaces: [Space]

    func resolve(_ origin: AgentOrigin) -> Space? {
        let matches = spaces.filter { $0.uuid == origin.spaceUUID && $0.displayID == origin.displayID }
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
    private var navigating = false

    init(backend: AgentOriginBackend,
         log: @escaping (String) -> Void = { swLog("SPACERETURN", $0) },
         wait: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.backend = backend
        self.log = log
        self.wait = wait
    }

    func navigate(to origin: AgentOrigin) async -> Bool {
        guard !navigating else { return false }
        navigating = true
        defer { navigating = false }
        let initial = backend.snapshot()
        guard let target = initial.resolve(origin) else {
            log("unavailable uuid=\(origin.spaceUUID) display=\(origin.displayID)")
            return false
        }
        let current = backend.currentSpace(on: origin.displayID)
        log("requested uuid=\(origin.spaceUUID) target=\(target.id) current=\(current ?? 0) display=\(origin.displayID)")
        if current == target.id { log("already on target=\(target.id)"); return true }
        guard initial.permitted else { log("accessibility unavailable"); return false }
        backend.requestSwitch(to: target)
        // Event posting and application activation are not evidence of arrival.
        // Require a stable destination, including the macOS 27 bounce interval.
        var consecutive = 0
        for _ in 0..<40 {
            guard !Task.isCancelled,
                  let resolved = backend.snapshot().resolve(origin), resolved.id == target.id else {
                log("cancelled or destination disappeared")
                return false
            }
            consecutive = backend.currentSpace(on: origin.displayID) == target.id ? consecutive + 1 : 0
            if consecutive >= 9 {
                log("confirmed uuid=\(origin.spaceUUID) current=\(target.id)")
                return true
            }
            await wait(.milliseconds(50))
        }
        log("not reached target=\(target.id) current=\(backend.currentSpace(on: origin.displayID) ?? 0)")
        return false
    }

    func origin(for event: AgentHookEvent) -> AgentOrigin? {
        guard let origin = event.origin, backend.snapshot().resolve(origin) != nil else { return nil }
        return origin
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
/// A foreground application is only relevant when it owns the hook's ancestor process.
/// Detached/ambiguous sessions stay unknown instead of using the completion-time desktop.
enum AgentSpaceCapture {
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

    static func select(windowSpaces: [[AgentOrigin]], foregroundSpace: AgentOrigin?) -> AgentOrigin? {
        // All-Spaces windows cannot establish where a session was submitted.
        let unique = Set(windowSpaces.compactMap { $0.count == 1 ? $0.first : nil })
        if let foregroundSpace, unique.contains(foregroundSpace) { return foregroundSpace }
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
        let spaces = spaces()
        let records = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let memberships: [[AgentOrigin]] = records.compactMap { record in
            guard record[kCGWindowOwnerPID as String] as? pid_t == owner,
                  record[kCGWindowLayer as String] as? Int == 0 else { return nil }
            guard let wid = record[kCGWindowNumber as String] as? UInt32,
                  let ids = CGSCopySpacesForWindows(CGSMainConnectionID(), 0x7, [wid] as CFArray) as? [UInt64] else { return [] }
            // Preserve ambiguity, including full-screen memberships we do not navigate to.
            guard ids.count == 1, let space = spaces.first(where: { $0.id == ids[0] }) else { return [] }
            return [space.origin]
        }
        var foreground: AgentOrigin?
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == owner,
           let display = CGSCopyActiveMenuBarDisplayIdentifier(CGSMainConnectionID()) as String? {
            let current = CGSManagedDisplayGetCurrentSpace(CGSMainConnectionID(), display as CFString)
            foreground = spaces.first { $0.displayID == display && $0.id == current }?.origin
        }
        return select(windowSpaces: memberships, foregroundSpace: foreground)
    }
}
