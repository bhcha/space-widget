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
                isFocused: isFocused,
                isHidden: false
            )
            items.append(item)
        }

        // Second pass: find hidden/minimized apps not in the on-screen list.
        // An app is "invisible" if it has AX windows on the current space that are
        // either all minimized or all off-screen (hidden). This works even when
        // NSRunningApplication.isHidden returns false (Electron apps).
        let visibleBundleIDs = Set(items.map(\.id))
        let onScreenPIDs = Set(seenPIDs)

        let candidateApps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular,
                  !app.isTerminated,
                  let bundleID = app.bundleIdentifier,
                  !visibleBundleIDs.contains(bundleID),
                  let name = app.localizedName,
                  !filteredAppNames.contains(name)
            else { return false }
            return !onScreenPIDs.contains(app.processIdentifier)
        }

        for app in candidateApps {
            let pid = app.processIdentifier
            var windowCount = 0
            forEachWindowOnCurrentSpace(pid: pid) { _, _, _ in
                windowCount += 1
                return false // continue — count all windows
            }
            guard windowCount > 0 else { continue }

            let bundleID = app.bundleIdentifier ?? "pid.\(pid)"
            let icon = resolveIcon(bundleID: bundleID, pid: pid)
            items.append(DockItem(
                id: bundleID,
                name: app.localizedName ?? "Unknown",
                icon: icon,
                pid: pid,
                windowCount: windowCount,
                isFocused: false,
                isHidden: true
            ))
        }

        // Sort by launch date (oldest first = stable launch order)
        // Cache launchDate to avoid repeated NSRunningApplication lookups in sort comparisons
        let launchDates: [pid_t: Date] = items.reduce(into: [:]) { dict, item in
            if dict[item.pid] == nil {
                dict[item.pid] = NSRunningApplication(processIdentifier: item.pid)?.launchDate ?? .distantPast
            }
        }
        items.sort { lhs, rhs in
            (launchDates[lhs.pid] ?? .distantPast) < (launchDates[rhs.pid] ?? .distantPast)
        }

        // Max 20 items
        return Array(items.prefix(20))
    }

    func fetchItems(
        screenFrame: CGRect,
        focusedBundleID: String?,
        ignoredApps: Set<String> = [],
        spaceID: UInt64
    ) -> [DockItem] {
        let filteredAppNames = baseFilteredAppNames.union(ignoredApps)

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: AnyObject]] else {
            return []
        }

        // Convert Cocoa screen frame to Quartz coordinates for intersection test
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
        let quartzY = primaryScreenHeight - screenFrame.maxY
        let quartzScreenRect = CGRect(x: screenFrame.origin.x, y: quartzY, width: screenFrame.width, height: screenFrame.height)

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

            // Filter by screen: check if window bounds intersect with this screen
            let isOnScreen = (window[kCGWindowIsOnscreen as String] as? Bool) ?? false
            guard isOnScreen else { continue }

            if let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat] {
                let windowRect = CGRect(
                    x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                    width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
                )
                guard quartzScreenRect.intersects(windowRect) else { continue }
            }

            if var existing = pidInfo[pid] {
                existing.windowCount += 1
                pidInfo[pid] = existing
            } else {
                seenPIDs.append(pid)
                if let app = NSRunningApplication(processIdentifier: pid) {
                    let bundleID = app.bundleIdentifier ?? "pid.\(pid)"
                    pidInfo[pid] = (bundleID: bundleID, name: app.localizedName ?? ownerName, windowCount: 1)
                } else {
                    pidInfo[pid] = (bundleID: "pid.\(pid)", name: ownerName, windowCount: 1)
                }
            }
        }

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
                isFocused: isFocused,
                isHidden: false
            )
            items.append(item)
        }

        // Hidden/minimized apps: use space-specific window enumeration
        let visibleBundleIDs = Set(items.map(\.id))
        let onScreenPIDs = Set(seenPIDs)

        let candidateApps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular,
                  !app.isTerminated,
                  let bundleID = app.bundleIdentifier,
                  !visibleBundleIDs.contains(bundleID),
                  let name = app.localizedName,
                  !filteredAppNames.contains(name)
            else { return false }
            return !onScreenPIDs.contains(app.processIdentifier)
        }

        for app in candidateApps {
            let pid = app.processIdentifier
            var windowCount = 0
            forEachWindowOnSpace(pid: pid, spaceID: spaceID) { _, _, _ in
                windowCount += 1
                return false
            }
            guard windowCount > 0 else { continue }

            let bundleID = app.bundleIdentifier ?? "pid.\(pid)"
            let icon = resolveIcon(bundleID: bundleID, pid: pid)
            items.append(DockItem(
                id: bundleID,
                name: app.localizedName ?? "Unknown",
                icon: icon,
                pid: pid,
                windowCount: windowCount,
                isFocused: false,
                isHidden: true
            ))
        }

        let launchDates: [pid_t: Date] = items.reduce(into: [:]) { dict, item in
            if dict[item.pid] == nil {
                dict[item.pid] = NSRunningApplication(processIdentifier: item.pid)?.launchDate ?? .distantPast
            }
        }
        items.sort { lhs, rhs in
            (launchDates[lhs.pid] ?? .distantPast) < (launchDates[rhs.pid] ?? .distantPast)
        }

        return Array(items.prefix(20))
    }

    /// Fetch items for multiple displays in a single CGWindowListCopyWindowInfo call.
    /// Returns a dictionary mapping display frames to their DockItems.
    func fetchItemsByDisplay(
        displays: [(displayID: String, screenFrame: CGRect, spaceID: UInt64)],
        focusedBundleID: String?,
        ignoredApps: Set<String> = []
    ) -> [String: [DockItem]] {
        let filteredAppNames = baseFilteredAppNames.union(ignoredApps)

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: AnyObject]] else {
            return [:]
        }

        // Pre-compute Quartz rects for all displays
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let quartzDisplays: [(displayID: String, quartzRect: CGRect, spaceID: UInt64)] = displays.map { d in
            let quartzY = primaryScreenHeight - d.screenFrame.maxY
            let quartzRect = CGRect(x: d.screenFrame.origin.x, y: quartzY,
                                    width: d.screenFrame.width, height: d.screenFrame.height)
            return (d.displayID, quartzRect, d.spaceID)
        }

        // Bucket windows by display
        // Each display gets its own seenPIDs and pidInfo
        var perDisplay: [String: (seenPIDs: [pid_t], pidInfo: [pid_t: (bundleID: String, name: String, windowCount: Int)])] = [:]
        for d in quartzDisplays {
            perDisplay[d.displayID] = (seenPIDs: [], pidInfo: [:])
        }

        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let ownerName = window[kCGWindowOwnerName as String] as? String,
                  !ownerName.isEmpty,
                  !filteredAppNames.contains(ownerName),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t
            else { continue }

            // Determine which display(s) this window belongs to
            var windowRect: CGRect?
            if let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat] {
                windowRect = CGRect(
                    x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                    width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
                )
            }

            for qd in quartzDisplays {
                if let wr = windowRect, !qd.quartzRect.intersects(wr) { continue }

                var state = perDisplay[qd.displayID]!
                if var existing = state.pidInfo[pid] {
                    existing.windowCount += 1
                    state.pidInfo[pid] = existing
                } else {
                    state.seenPIDs.append(pid)
                    if let app = NSRunningApplication(processIdentifier: pid) {
                        let bundleID = app.bundleIdentifier ?? "pid.\(pid)"
                        state.pidInfo[pid] = (bundleID: bundleID, name: app.localizedName ?? ownerName, windowCount: 1)
                    } else {
                        state.pidInfo[pid] = (bundleID: "pid.\(pid)", name: ownerName, windowCount: 1)
                    }
                }
                perDisplay[qd.displayID] = state
            }
        }

        // Build DockItems per display
        var result: [String: [DockItem]] = [:]

        for qd in quartzDisplays {
            let state = perDisplay[qd.displayID]!
            let seenPIDs = state.seenPIDs
            let pidInfo = state.pidInfo

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

            var items: [DockItem] = []
            var addedBundles = Set<String>()

            for pid in seenPIDs {
                guard let info = pidInfo[pid] else { continue }
                guard !addedBundles.contains(info.bundleID) else { continue }
                addedBundles.insert(info.bundleID)
                guard let bundleEntry = byBundle[info.bundleID] else { continue }
                let icon = resolveIcon(bundleID: info.bundleID, pid: bundleEntry.pid)
                let isFocused = info.bundleID == focusedBundleID

                items.append(DockItem(
                    id: info.bundleID, name: bundleEntry.name, icon: icon,
                    pid: bundleEntry.pid, windowCount: bundleEntry.windowCount,
                    isFocused: isFocused, isHidden: false
                ))
            }

            // Hidden/minimized apps for this display's space
            let visibleBundleIDs = Set(items.map(\.id))
            let onScreenPIDs = Set(seenPIDs)

            let candidateApps = NSWorkspace.shared.runningApplications.filter { app in
                guard app.activationPolicy == .regular,
                      !app.isTerminated,
                      let bundleID = app.bundleIdentifier,
                      !visibleBundleIDs.contains(bundleID),
                      let name = app.localizedName,
                      !filteredAppNames.contains(name)
                else { return false }
                return !onScreenPIDs.contains(app.processIdentifier)
            }

            for app in candidateApps {
                let pid = app.processIdentifier
                var windowCount = 0
                forEachWindowOnSpace(pid: pid, spaceID: qd.spaceID) { _, _, _ in
                    windowCount += 1
                    return false
                }
                guard windowCount > 0 else { continue }

                let bundleID = app.bundleIdentifier ?? "pid.\(pid)"
                let icon = resolveIcon(bundleID: bundleID, pid: pid)
                items.append(DockItem(
                    id: bundleID, name: app.localizedName ?? "Unknown", icon: icon,
                    pid: pid, windowCount: windowCount, isFocused: false, isHidden: true
                ))
            }

            // Sort by launch date
            let launchDates: [pid_t: Date] = items.reduce(into: [:]) { dict, item in
                if dict[item.pid] == nil {
                    dict[item.pid] = NSRunningApplication(processIdentifier: item.pid)?.launchDate ?? .distantPast
                }
            }
            items.sort { lhs, rhs in
                (launchDates[lhs.pid] ?? .distantPast) < (launchDates[rhs.pid] ?? .distantPast)
            }

            result[qd.displayID] = Array(items.prefix(20))
        }

        return result
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
