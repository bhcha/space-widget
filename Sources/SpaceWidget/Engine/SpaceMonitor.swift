import AppKit
import Combine

final class SpaceMonitor: ObservableObject {
    @Published private(set) var currentSpace: ActiveSpace = ActiveSpace(id: 0, ordinal: 1)

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
        debounceTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.refresh(immediate: false)
        }
        debounceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: task)
    }

    func refresh(immediate: Bool = false) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.refresh(immediate: immediate) }
            return
        }

        guard let resolved = resolveCurrentSpace() else { return }
        commitSpace(resolved)
    }

    /// Resolve the current space ID and ordinal from CGS APIs.
    private func resolveCurrentSpace() -> ActiveSpace? {
        let cid = CGSMainConnectionID()
        let displays = CGSCopyManagedDisplaySpaces(cid) as [AnyObject]

        let mainDisplayID = CGMainDisplayID()
        let mainDisplayIdentifier: String?
        let spaceID: UInt64

        if let displayUUIDUnmanaged = CGDisplayCreateUUIDFromDisplayID(mainDisplayID),
           let uuidCFString = CFUUIDCreateString(nil, displayUUIDUnmanaged.takeRetainedValue()) {
            let displayIdentifier = uuidCFString as String
            mainDisplayIdentifier = displayIdentifier
            spaceID = CGSManagedDisplayGetCurrentSpace(cid, uuidCFString as CFString)
        } else {
            mainDisplayIdentifier = nil
            spaceID = CGSManagedDisplayGetCurrentSpace(cid, "Main" as CFString)
        }

        let spaceType = CGSSpaceGetType(cid, spaceID)
        let resolution = resolveManagedSpaceInfo(
            displays: displays,
            currentSpaceID: spaceID,
            mainDisplayIdentifier: mainDisplayIdentifier
        )

        swLog(
            "SPACE",
            "metadata id=\(spaceID) type=\(spaceType) listed=\(resolution.isListed) ordinal=\(resolution.ordinal) userSpaces=\(resolution.userSpaceCount) display=\(resolution.displayIdentifier)"
        )

        if spaceType != 0 {
            swLog("SPACE", "skipping non-desktop current space id=\(spaceID) type=\(spaceType)")
            return nil
        }

        if !resolution.isListed {
            swLog("SPACE", "skipping unmanaged current space id=\(spaceID) type=\(spaceType) display=\(resolution.displayIdentifier)")
            return nil
        }

        return ActiveSpace(id: spaceID, ordinal: resolution.ordinal)
    }

    private func commitSpace(_ space: ActiveSpace) {
        currentSpace = space
    }

    private func resolveManagedSpaceInfo(
        displays: [AnyObject],
        currentSpaceID: UInt64,
        mainDisplayIdentifier: String?
    ) -> (ordinal: Int, isListed: Bool, userSpaceCount: Int, displayIdentifier: String) {
        var ordinal = 1
        var counter = 1
        var isListed = false
        var userSpaceCount = 0
        var matchedDisplayIdentifier = mainDisplayIdentifier ?? "unknown"

        for display in displays {
            guard let displayDict = display as? [String: AnyObject],
                  let spaces = displayDict["Spaces"] as? [[String: AnyObject]]
            else { continue }

            let displayIdentifier = displayDict["Display Identifier"] as? String ?? "unknown"
            let isTargetDisplay: Bool
            if let mainDisplayIdentifier {
                isTargetDisplay = displayIdentifier == mainDisplayIdentifier
            } else {
                isTargetDisplay = true
            }

            for space in spaces {
                guard let sid = space["id64"] as? UInt64 else { continue }
                let listedType = (space["type"] as? NSNumber)?.intValue ?? 0
                if listedType == 0 {
                    if isTargetDisplay {
                        userSpaceCount += 1
                    }
                    if sid == currentSpaceID {
                        isListed = true
                        matchedDisplayIdentifier = displayIdentifier
                    }
                    if sid == currentSpaceID {
                        ordinal = counter
                    }
                    counter += 1
                }
            }
        }

        return (ordinal, isListed, userSpaceCount, matchedDisplayIdentifier)
    }
}
