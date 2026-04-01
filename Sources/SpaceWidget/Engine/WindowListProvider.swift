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

        // Map pid -> (bundleID, name, windowCount)
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
                // Try to get bundle ID from running application
                if let app = NSRunningApplication(processIdentifier: pid) {
                    let bundleID = app.bundleIdentifier ?? "pid.\(pid)"
                    pidInfo[pid] = (bundleID: bundleID, name: app.localizedName ?? ownerName, windowCount: 1)
                } else {
                    pidInfo[pid] = (bundleID: "pid.\(pid)", name: ownerName, windowCount: 1)
                }
            }
        }

        // Deduplicate by bundle ID (keep entry with highest window count if same bundle)
        var byBundle: [String: (pid: pid_t, name: String, windowCount: Int)] = [:]

        for (pid, info) in pidInfo {
            if let existing = byBundle[info.bundleID] {
                if info.windowCount > existing.windowCount {
                    byBundle[info.bundleID] = (pid: pid, name: info.name, windowCount: info.windowCount)
                }
            } else {
                byBundle[info.bundleID] = (pid: pid, name: info.name, windowCount: info.windowCount)
            }
        }

        // Build DockItems
        var items: [DockItem] = []

        for (bundleID, info) in byBundle {
            let icon = resolveIcon(bundleID: bundleID, pid: info.pid)
            let isFocused = bundleID == focusedBundleID

            let item = DockItem(
                id: bundleID,
                name: info.name,
                icon: icon,
                pid: info.pid,
                windowCount: info.windowCount,
                isFocused: isFocused
            )
            items.append(item)
        }

        // Sort alphabetically (stable default order; ViewModel handles user reordering)
        items.sort { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
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
