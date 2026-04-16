import AppKit
import CoreGraphics

// MARK: - Reachability classification

enum SpaceReachability: CustomStringConvertible {
    case unique      // non-sticky window exclusively on this space
    case ambiguous   // app has windows on target AND other spaces (non-sticky)
    case stickyOnly  // only all-spaces windows on this space
    case empty       // no layer-0 windows at all

    var description: String {
        switch self {
        case .unique: return "unique"
        case .ambiguous: return "ambiguous"
        case .stickyOnly: return "stickyOnly"
        case .empty: return "empty"
        }
    }
}

// MARK: - Candidate window info

struct SpaceCandidate {
    let pid: pid_t
    let wid: CGWindowID
    let spaces: [UInt64]     // all spaces this window belongs to
    var isUnique: Bool { spaces.count == 1 }
}

// MARK: - Global snapshot (built once per menu open)

struct SpaceSnapshot {
    /// For each spaceID that has at least one candidate, the list of candidate windows.
    let candidatesBySpace: [UInt64: [SpaceCandidate]]
    let totalSpaceCount: Int
    let spacesByDisplay: [String: [UInt64]]

    static func capture() -> SpaceSnapshot {
        let cid = CGSMainConnectionID()
        guard let windowList = CGWindowListCopyWindowInfo(
            [],                         // no .optionOnScreenOnly — we want off-space windows too
            kCGNullWindowID
        ) as? [[String: AnyObject]] else {
            return SpaceSnapshot(candidatesBySpace: [:], totalSpaceCount: 0, spacesByDisplay: [:])
        }

        var candidatesBySpace: [UInt64: [SpaceCandidate]] = [:]
        var scanned = 0
        var regularFiltered = 0
        var withSpaces = 0

        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,  // normal layer only
                  let wid = window[kCGWindowNumber as String] as? CGWindowID,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }
            scanned += 1

            // Filter to regular-activation-policy apps (skip menu bar items, agents, etc.)
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular else {
                continue
            }
            regularFiltered += 1

            // Query which spaces this window belongs to
            guard let spaces = CGSCopySpacesForWindows(cid, 0x7, [wid] as CFArray) as? [UInt64],
                  !spaces.isEmpty else {
                continue
            }
            withSpaces += 1

            let candidate = SpaceCandidate(pid: pid, wid: wid, spaces: spaces)
            for spaceID in spaces {
                candidatesBySpace[spaceID, default: []].append(candidate)
            }
        }

        // Total space count from CGS (authoritative). Iterates all displays' spaces.
        // Also dump raw per-display space ordering for diagnostics.
        var total = 0
        var spacesByDisplay: [String: [UInt64]] = [:]
        if let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: AnyObject]] {
            for display in displays {
                let displayID = (display["Display Identifier"] as? String) ?? "?"
                let currentRaw = display["Current Space"] as? [String: AnyObject]
                let currentID = (currentRaw?["ManagedSpaceID"] as? UInt64) ?? 0
                guard let spaces = display["Spaces"] as? [[String: AnyObject]] else { continue }

                var entries: [String] = []
                var perDisplaySpaces: [UInt64] = []
                var idx = 0
                for space in spaces {
                    let sid = (space["ManagedSpaceID"] as? UInt64) ?? (space["id64"] as? UInt64) ?? 0
                    let type = (space["type"] as? NSNumber)?.intValue ?? 0
                    if type == 0 {
                        idx += 1
                        total += 1
                        entries.append("(idx=\(idx),id=\(sid),type=\(type))")
                        perDisplaySpaces.append(sid)
                    }
                }
                spacesByDisplay[displayID] = perDisplaySpaces
                swLog("SWITCH", "rawDisplay id=\(displayID) current=\(currentID) spaces=[\(entries.joined(separator: ","))]")
            }
        }

        swLog("SWITCH", "snapshot capture: scanned=\(scanned) regular=\(regularFiltered) withSpaces=\(withSpaces) spaces=\(candidatesBySpace.count) total=\(total)")
        return SpaceSnapshot(candidatesBySpace: candidatesBySpace, totalSpaceCount: total, spacesByDisplay: spacesByDisplay)
    }

    /// Returns the number of type-0 spaces on the display that contains `spaceID`,
    /// or `totalSpaceCount` as fallback if the space isn't found in any display.
    func displaySpaceCount(for spaceID: UInt64) -> Int {
        for (_, spaces) in spacesByDisplay where spaces.contains(spaceID) {
            return spaces.count
        }
        return totalSpaceCount
    }

    func reachability(for spaceID: UInt64) -> SpaceReachability {
        guard let candidates = candidatesBySpace[spaceID], !candidates.isEmpty else {
            return .empty
        }

        let uniqueCandidates = candidates.filter { $0.isUnique }
        if !uniqueCandidates.isEmpty {
            return .unique
        }

        // Sticky threshold: the number of spaces on the display that owns `spaceID`.
        // A sticky (all-spaces) window on display D will belong to all of D's spaces
        // but not spaces on other displays, so we must compare against D's count, not global.
        let perDisplay = displaySpaceCount(for: spaceID)
        let threshold = max(perDisplay, 2)
        let allLookLikeSticky = candidates.allSatisfy { $0.spaces.count >= threshold }
        return allLookLikeSticky ? .stickyOnly : .ambiguous
    }

    /// Best candidate to activate for switching to the target space.
    /// Prefers unique (non-sticky, single-space) candidates.
    func bestCandidate(for spaceID: UInt64) -> SpaceCandidate? {
        guard let candidates = candidatesBySpace[spaceID], !candidates.isEmpty else {
            return nil
        }
        // Prefer unique (single-space) candidates
        if let unique = candidates.first(where: { $0.isUnique }) {
            return unique
        }
        // Fall back: candidate with fewest spaces (less ambiguous)
        return candidates.min(by: { $0.spaces.count < $1.spaces.count })
    }
}

// MARK: - SpaceSwitcher

enum SpaceSwitcher {
    // MARK: - Dock-Swipe CGEvent Fields (from WhichSpace)

    private enum Field {
        static let eventType = CGEventField(rawValue: 55)!
        static let gestureHIDType = CGEventField(rawValue: 110)!
        static let gestureScrollY = CGEventField(rawValue: 119)!
        static let gestureSwipeMotion = CGEventField(rawValue: 123)!
        static let gestureSwipeProgress = CGEventField(rawValue: 124)!
        static let gestureSwipeVelocityX = CGEventField(rawValue: 129)!
        static let gestureSwipeVelocityY = CGEventField(rawValue: 130)!
        static let gesturePhase = CGEventField(rawValue: 132)!
        static let scrollGestureFlagBits = CGEventField(rawValue: 135)!
        static let gestureZoomDeltaX = CGEventField(rawValue: 139)!
    }

    private enum EventType {
        static let gesture: Int64 = 29
        static let dockControl: Int64 = 30
    }

    private static let hidTypeDockSwipe: Int64 = 23

    private enum Phase {
        static let began: Int64 = 1
        static let ended: Int64 = 4
    }

    private static let horizontalMotion: Int64 = 1
    private static let swipeVelocity = 400.0
    private static let swipeProgress = 2.0

    // MARK: - Public API

    @discardableResult
    static func switchTo(
        spaceID: UInt64,
        ordinal: Int,
        displayID: String,
        snapshot: SpaceSnapshot? = nil
    ) -> Bool {
        swLog("SWITCH", "requested spaceID=\(spaceID) ordinal=\(ordinal) display=\(displayID)")

        // Primary: dock-swipe gesture synthesis
        if switchViaDockSwipe(targetSpaceID: spaceID, displayID: displayID) {
            return true
        }

        // Secondary: Ctrl+N keyboard shortcut
        if tryShortcutFallback(ordinal: ordinal, displayID: displayID) {
            return true
        }

        swLog("SWITCH", "no switch path available for spaceID=\(spaceID)")
        return false
    }

    static func reachability(for spaceID: UInt64, snapshot: SpaceSnapshot? = nil) -> SpaceReachability {
        let snap = snapshot ?? SpaceSnapshot.capture()
        return snap.reachability(for: spaceID)
    }

    // MARK: - Dock-Swipe Gesture Synthesis

    private static func switchViaDockSwipe(targetSpaceID: UInt64, displayID: String) -> Bool {
        let cid = CGSMainConnectionID()

        // Dock-swipe gestures are applied to the active menu bar display.
        // If the target display differs, bail out so the fallback can handle it.
        if let activeDisplayCF = CGSCopyActiveMenuBarDisplayIdentifier(cid) {
            let activeDisplay = activeDisplayCF as String
            if activeDisplay != displayID {
                swLog("SWITCH", "dockSwipe: active display \(activeDisplay) != target \(displayID), skipping")
                return false
            }
        }

        guard let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: AnyObject]] else {
            swLog("SWITCH", "dockSwipe: failed to get managed display spaces")
            return false
        }

        // Find the display matching our target displayID
        guard let displayDict = displays.first(where: {
            ($0["Display Identifier"] as? String) == displayID
        }) else {
            swLog("SWITCH", "dockSwipe: display \(displayID) not found")
            return false
        }

        guard let spaces = displayDict["Spaces"] as? [[String: AnyObject]] else {
            swLog("SWITCH", "dockSwipe: no spaces array for display")
            return false
        }

        guard let currentSpaceDict = displayDict["Current Space"] as? [String: AnyObject],
              let activeSpaceID = (currentSpaceDict["ManagedSpaceID"] as? UInt64) ?? (currentSpaceDict["id64"] as? UInt64) else {
            swLog("SWITCH", "dockSwipe: failed to get current space for display")
            return false
        }

        // Find 0-based indices of current and target spaces
        var currentIndex: Int?
        var targetIndex: Int?

        for (index, space) in spaces.enumerated() {
            let sid = (space["ManagedSpaceID"] as? UInt64) ?? (space["id64"] as? UInt64) ?? 0
            if sid == activeSpaceID { currentIndex = index }
            if sid == targetSpaceID { targetIndex = index }
        }

        guard let current = currentIndex, let target = targetIndex else {
            swLog("SWITCH", "dockSwipe: could not find current(\(activeSpaceID)) or target(\(targetSpaceID)) in display spaces")
            return false
        }

        guard current != target else {
            swLog("SWITCH", "dockSwipe: already on target space")
            return true
        }

        let steps = abs(target - current)
        let goRight = target > current
        swLog("SWITCH", "dockSwipe: current=\(current) target=\(target) steps=\(steps) goRight=\(goRight)")

        for i in 0..<steps {
            postSwipeGesture(goRight: goRight)
            if i < steps - 1 {
                usleep(50_000) // 50ms between steps for animation to settle
            }
        }

        // Verify the switch actually took effect
        usleep(100_000) // 100ms for the switch to settle
        let verifyID = CGSManagedDisplayGetCurrentSpace(cid, displayID as CFString)
        let switched = (verifyID == targetSpaceID)
        swLog("SWITCH", "dockSwipe: postVerify current=\(verifyID) target=\(targetSpaceID) switched=\(switched)")
        return switched
    }

    private static func postSwipeGesture(goRight: Bool) {
        let flagDirection: Int64 = goRight ? 1 : 0
        let progress = goRight ? swipeProgress : -swipeProgress
        let velocity = goRight ? swipeVelocity : -swipeVelocity

        // Begin gesture
        guard let gestureA = CGEvent(source: nil),
              let controlA = CGEvent(source: nil) else { return }

        gestureA.setIntegerValueField(Field.eventType, value: EventType.gesture)

        controlA.setIntegerValueField(Field.eventType, value: EventType.dockControl)
        controlA.setIntegerValueField(Field.gestureHIDType, value: hidTypeDockSwipe)
        controlA.setIntegerValueField(Field.gesturePhase, value: Phase.began)
        controlA.setIntegerValueField(Field.scrollGestureFlagBits, value: flagDirection)
        controlA.setIntegerValueField(Field.gestureSwipeMotion, value: horizontalMotion)
        controlA.setDoubleValueField(Field.gestureScrollY, value: 0)
        controlA.setDoubleValueField(Field.gestureZoomDeltaX, value: Double(Float.leastNonzeroMagnitude))

        controlA.post(tap: .cgSessionEventTap)
        gestureA.post(tap: .cgSessionEventTap)

        // End gesture
        guard let gestureB = CGEvent(source: nil),
              let controlB = CGEvent(source: nil) else { return }

        gestureB.setIntegerValueField(Field.eventType, value: EventType.gesture)

        controlB.setIntegerValueField(Field.eventType, value: EventType.dockControl)
        controlB.setIntegerValueField(Field.gestureHIDType, value: hidTypeDockSwipe)
        controlB.setIntegerValueField(Field.gesturePhase, value: Phase.ended)
        controlB.setDoubleValueField(Field.gestureSwipeProgress, value: progress)
        controlB.setIntegerValueField(Field.scrollGestureFlagBits, value: flagDirection)
        controlB.setIntegerValueField(Field.gestureSwipeMotion, value: horizontalMotion)
        controlB.setDoubleValueField(Field.gestureScrollY, value: 0)
        controlB.setDoubleValueField(Field.gestureSwipeVelocityX, value: velocity)
        controlB.setDoubleValueField(Field.gestureSwipeVelocityY, value: 0)
        controlB.setDoubleValueField(Field.gestureZoomDeltaX, value: Double(Float.leastNonzeroMagnitude))

        controlB.post(tap: .cgSessionEventTap)
        gestureB.post(tap: .cgSessionEventTap)
    }

    // MARK: - Keyboard Shortcut Fallback

    private static func tryShortcutFallback(ordinal: Int, displayID: String) -> Bool {
        guard ordinal >= 1 && ordinal <= 9 else {
            swLog("SWITCH", "shortcut skipped — ordinal \(ordinal) out of 1...9")
            return false
        }

        let canUse = NSScreen.screens.count <= 1 || NSScreen.screensHaveSeparateSpaces
        guard canUse else {
            swLog("SWITCH", "skipping Ctrl+\(ordinal) — shared Spaces multi-display")
            return false
        }

        let enabled = enabledSwitchToDesktopOrdinals()
        guard enabled.contains(ordinal) else {
            swLog("SWITCH", "shortcut skipped — Ctrl+\(ordinal) not enabled (enabled=\(enabled.sorted()))")
            return false
        }

        if postCtrlNumberShortcut(ordinal: ordinal, displayID: displayID) {
            swLog("SWITCH", "posted Ctrl+\(ordinal) fallback")
            return true
        }
        return false
    }

    // MARK: - Symbolichotkeys detection

    static func enabledSwitchToDesktopOrdinals() -> Set<Int> {
        let keyCodeToOrdinal: [Int: Int] = [
            0x12: 1, 0x13: 2, 0x14: 3, 0x15: 4, 0x17: 5,
            0x16: 6, 0x1A: 7, 0x1C: 8, 0x19: 9
        ]
        let controlMask = 0x40000
        let switchToDesktopIDRange = 118...135

        guard let hotKeysCF = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString
        ),
              let hotKeys = hotKeysCF as? [String: Any] else {
            return []
        }

        var result = Set<Int>()
        for (keyString, value) in hotKeys {
            guard let hotkeyID = Int(keyString),
                  switchToDesktopIDRange.contains(hotkeyID) else { continue }

            guard let entry = value as? [String: Any],
                  (entry["enabled"] as? Bool) == true,
                  let valueDict = entry["value"] as? [String: Any],
                  let parameters = valueDict["parameters"] as? [Int],
                  parameters.count >= 3 else { continue }

            let virtualKey = parameters[1]
            let modifiers = parameters[2]
            guard modifiers == controlMask else { continue }

            if let ordinal = keyCodeToOrdinal[virtualKey] {
                result.insert(ordinal)
            }
        }
        return result
    }

    private static func postCtrlNumberShortcut(ordinal: Int, displayID: String) -> Bool {
        let keyCodes: [Int: CGKeyCode] = [
            1: 0x12, 2: 0x13, 3: 0x14, 4: 0x15, 5: 0x17,
            6: 0x16, 7: 0x1A, 8: 0x1C, 9: 0x19
        ]
        guard let keyCode = keyCodes[ordinal] else { return false }

        let mouseLoc = NSEvent.mouseLocation
        guard let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLoc) }),
              displayIdentifier(for: cursorScreen) == displayID else {
            swLog("SWITCH", "Ctrl+\(ordinal) skipped — cursor not on display=\(displayID)")
            return false
        }

        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskControl
        keyUp.flags = .maskControl
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
