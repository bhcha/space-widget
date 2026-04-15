import AppKit
import Combine

final class SpaceMonitor: ObservableObject {
    @Published private(set) var displaySpaces: [String: ActiveSpace] = [:]

    var currentSpace: ActiveSpace {
        displaySpaces[mainDisplayIdentifier] ?? ActiveSpace(id: 0, ordinal: 1)
    }

    var mainDisplayIdentifier: String {
        let mainDisplayID = CGMainDisplayID()
        if let uuid = CGDisplayCreateUUIDFromDisplayID(mainDisplayID),
           let uuidString = CFUUIDCreateString(nil, uuid.takeRetainedValue()) {
            return uuidString as String
        }
        return "Main"
    }

    private var debounceTask: DispatchWorkItem?

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(spaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        refresh(immediate: true)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func spaceDidChange() {
        swLog("EVENT", "nsworkspace.activeSpaceDidChangeNotification received")
        debounceTask?.cancel()
        swLog("EVENT", "space debounce cancelled_previous=true")
        let task = DispatchWorkItem { [weak self] in
            swLog("EVENT", "space debounce fired")
            self?.refresh(immediate: false)
        }
        debounceTask = task
        swLog("EVENT", "space debounce scheduled delay=0.1 immediate=false")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: task)
    }

    func refresh(immediate: Bool = false) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.refresh(immediate: immediate) }
            return
        }

        swLog("EVENT", "space refresh begin immediate=\(immediate)")
        let resolved = resolveAllSpaces()
        commitSpaces(resolved)
    }

    /// Full per-display list of type-0 (desktop) spaces with their computed ordinals.
    /// Returns dict: displayID -> [(spaceID, ordinal)] in ordinal order.
    func resolveAllSpaceLists() -> [String: [(spaceID: UInt64, ordinal: Int)]] {
        let cid = CGSMainConnectionID()
        let displays = CGSCopyManagedDisplaySpaces(cid) as [AnyObject]

        var result: [String: [(spaceID: UInt64, ordinal: Int)]] = [:]
        for display in displays {
            guard let displayDict = display as? [String: AnyObject],
                  let spaces = displayDict["Spaces"] as? [[String: AnyObject]],
                  let displayIdentifier = displayDict["Display Identifier"] as? String
            else { continue }

            var list: [(spaceID: UInt64, ordinal: Int)] = []
            var counter = 1
            for space in spaces {
                guard let sid = space["id64"] as? UInt64 else { continue }
                let listedType = (space["type"] as? NSNumber)?.intValue ?? 0
                if listedType == 0 {
                    list.append((spaceID: sid, ordinal: counter))
                    counter += 1
                }
            }
            result[displayIdentifier] = list
        }
        return result
    }

    private func resolveAllSpaces() -> [String: ActiveSpace] {
        let cid = CGSMainConnectionID()
        let displays = CGSCopyManagedDisplaySpaces(cid) as [AnyObject]

        var result: [String: ActiveSpace] = [:]

        for display in displays {
            guard let displayDict = display as? [String: AnyObject],
                  let spaces = displayDict["Spaces"] as? [[String: AnyObject]],
                  let displayIdentifier = displayDict["Display Identifier"] as? String
            else { continue }

            let displayIDCF = displayIdentifier as CFString
            let spaceID = CGSManagedDisplayGetCurrentSpace(cid, displayIDCF)
            let spaceType = CGSSpaceGetType(cid, spaceID)

            if spaceType != 0 {
                swLog("SPACE", "skipping non-desktop current space id=\(spaceID) type=\(spaceType) display=\(displayIdentifier)")
                continue
            }

            // Compute ordinal per-display (only type-0 spaces in this display)
            var ordinal = 1
            var counter = 1
            var isListed = false

            for space in spaces {
                guard let sid = space["id64"] as? UInt64 else { continue }
                let listedType = (space["type"] as? NSNumber)?.intValue ?? 0
                if listedType == 0 {
                    if sid == spaceID {
                        ordinal = counter
                        isListed = true
                    }
                    counter += 1
                }
            }

            if !isListed {
                swLog("SPACE", "skipping unmanaged current space id=\(spaceID) display=\(displayIdentifier)")
                continue
            }

            swLog("SPACE", "metadata id=\(spaceID) ordinal=\(ordinal) display=\(displayIdentifier)")
            result[displayIdentifier] = ActiveSpace(id: spaceID, ordinal: ordinal)
        }

        return result
    }

    private func commitSpaces(_ resolvedSpaces: [String: ActiveSpace]) {
        for (displayID, space) in resolvedSpaces {
            swLog("EVENT", "space commit display=\(displayID) ordinal=\(space.ordinal) id=\(space.id)")
        }
        displaySpaces = resolvedSpaces
    }
}
