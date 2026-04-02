import AppKit

/// System apps that are always filtered, regardless of user config.
private let baseFilteredAppNames: Set<String> = [
    "System Events",
    "Dock",
    "SystemUIServer",
    "Control Center",
    "Notification Center",
    "loginwindow",
    "WindowManager",
    "TextInputMenuAgent"
]

final class WindowListProvider {

    private let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 50
        return cache
    }()

    func fetchItems(focusedBundleID: String?, ignoredApps: Set<String> = []) -> [DockItem] {
        let filteredAppNames = baseFilteredAppNames.union(ignoredApps)
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: AnyObject]] else {
            return []
        }

        // Map pid -> (bundleID, name, windowCount); seenPIDs tracks first-seen z-order
        var seenPIDs: [pid_t] = []
        var pidInfo: [pid_t: (bundleID: String, name: String, windowCount: Int)] = [:]

        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let ownerName = window[kCGWindowOwnerName as String] as? String,
                  !ownerName.isEmpty,
                  !filteredAppNames.contains(ownerName),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t
            else { continue }

            if var existing = pidInfo[pid] {
                existing.windowCount += 1
                pidInfo[pid] = existing
            } else {
                seenPIDs.append(pid)
                // Try to get bundle ID from running application
                if let app = NSRunningApplication(processIdentifier: pid) {
                    let bundleID = app.bundleIdentifier ?? "pid.\(pid)"
                    pidInfo[pid] = (bundleID: bundleID, name: app.localizedName ?? ownerName, windowCount: 1)
                } else {
                    pidInfo[pid] = (bundleID: "pid.\(pid)", name: ownerName, windowCount: 1)
                }
            }
        }

        // Deduplicate by bundle ID.
        // Keep the first-seen pid (topmost in z-order) and accumulate window counts.
        var byBundle: [String: (pid: pid_t, name: String, windowCount: Int)] = [:]

        for pid in seenPIDs {
            guard let info = pidInfo[pid] else { continue }
            if var existing = byBundle[info.bundleID] {
                existing.windowCount += info.windowCount
                byBundle[info.bundleID] = existing
            } else {
                byBundle[info.bundleID] = (pid: pid, name: info.name, windowCount: info.windowCount)
            }
        }

        // Build DockItems in first-seen z-order (frontmost first)
        var items: [DockItem] = []
        var addedBundles = Set<String>()

        for pid in seenPIDs {
            guard let info = pidInfo[pid] else { continue }
            guard !addedBundles.contains(info.bundleID) else { continue }
            addedBundles.insert(info.bundleID)
            guard let bundleEntry = byBundle[info.bundleID] else { continue }
            let icon = resolveIcon(bundleID: info.bundleID, pid: bundleEntry.pid)
            let isFocused = info.bundleID == focusedBundleID

            let item = DockItem(
                id: info.bundleID,
                name: bundleEntry.name,
                icon: icon,
                pid: bundleEntry.pid,
                windowCount: bundleEntry.windowCount,
                isFocused: isFocused
            )
            items.append(item)
        }

        // Sort by launch date (oldest first = stable launch order)
        items.sort { lhs, rhs in
            let lhsDate = NSRunningApplication(processIdentifier: lhs.pid)?.launchDate ?? .distantPast
            let rhsDate = NSRunningApplication(processIdentifier: rhs.pid)?.launchDate ?? .distantPast
            return lhsDate < rhsDate
        }

        // Max 20 items
        return Array(items.prefix(20))
    }

    private func resolveIcon(bundleID: String, pid: pid_t) -> NSImage {
        if let cached = iconCache.object(forKey: bundleID as NSString) {
            return cached
        }

        let icon: NSImage
        if let app = NSRunningApplication(processIdentifier: pid),
           let appIcon = app.icon {
            icon = appIcon
        } else {
            icon = NSWorkspace.shared.icon(forFileType: "app")
        }

        iconCache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }

    func clearCache() {
        iconCache.removeAllObjects()
    }
}
