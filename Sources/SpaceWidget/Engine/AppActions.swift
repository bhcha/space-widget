import AppKit
import ApplicationServices

enum AppActions {
    static func canOpenNewWindow(pid: pid_t) -> Bool {
        findCmdNMenuItem(pid: pid) { _, _ in true }
    }

    @discardableResult
    static func openNewWindow(pid: pid_t) -> Bool {
        let found = findCmdNMenuItem(pid: pid) { menuItem, menuBarItem in
            // Try direct press first
            if AXUIElementPerformAction(menuItem, kAXPressAction as CFString) == .success {
                return true
            }
            // Fall back: open parent menu, then press the item
            AXUIElementPerformAction(menuBarItem, kAXPressAction as CFString)
            let result = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
            // Close the menu if the second attempt also failed
            if result != .success {
                AXUIElementPerformAction(menuBarItem, kAXCancelAction as CFString)
            }
            return result == .success ? true : nil
        }
        if found { return true }
        // CGEvent fallback: post Cmd+N directly to the process
        let source = CGEventSource(stateID: .hidSystemState)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x2D, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.postToPid(pid)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x2D, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.postToPid(pid)
        }
        return false
    }

    static func closeWindowsOnCurrentSpace(pid: pid_t, spaceID: UInt64? = nil) {
        let body: (_ appElement: AXUIElement, _ axWindow: AXUIElement, _ wid: CGWindowID) -> Bool = { _, axWindow, _ in
            var closeButtonRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
                  let closeButtonRef else { return false }
            // swiftlint:disable:next force_cast
            AXUIElementPerformAction(closeButtonRef as! AXUIElement, kAXPressAction as CFString)
            return false // continue — close all matching windows
        }
        if let spaceID = spaceID {
            forEachWindowOnSpace(pid: pid, spaceID: spaceID, singleSpaceOnly: true, body: body)
        } else {
            forEachWindowOnCurrentSpace(pid: pid, singleSpaceOnly: true, body: body)
        }
    }

    static func activateApp(pid: pid_t, spaceID: UInt64? = nil) {
        let body: (_ appElement: AXUIElement, _ axWindow: AXUIElement, _ wid: CGWindowID) -> Bool = { appElement, axWindow, wid in
            let raiseResult = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            let frontResult = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue as CFTypeRef)
            if raiseResult == .success && frontResult == .success {
                return true
            }
            swLog("ACTIVATE", "AXAction failed pid=\(pid) wid=\(wid) raise=\(raiseResult.rawValue) front=\(frontResult.rawValue), trying next window")
            return false
        }
        if let spaceID = spaceID {
            forEachWindowOnSpace(pid: pid, spaceID: spaceID, body: body)
        } else {
            forEachWindowOnCurrentSpace(pid: pid, body: body)
        }
    }

    static func restoreAndActivate(pid: pid_t, spaceID: UInt64? = nil) {
        let appElement = AXUIElementCreateApplication(pid)

        // Unhide if the app is hidden
        AXUIElementSetAttributeValue(appElement, kAXHiddenAttribute as CFString, kCFBooleanFalse)

        // Unminimize windows on the current space
        let unminimizeBody: (_ appElement: AXUIElement, _ axWindow: AXUIElement, _ wid: CGWindowID) -> Bool = { _, axWindow, _ in
            var minRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minRef) == .success,
               (minRef as? Bool) == true {
                AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            return false // continue — unminimize all windows on this space
        }
        if let spaceID = spaceID {
            forEachWindowOnSpace(pid: pid, spaceID: spaceID, body: unminimizeBody)
        } else {
            forEachWindowOnCurrentSpace(pid: pid, body: unminimizeBody)
        }

        // Small delay to let restore take effect before raising
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            activateApp(pid: pid, spaceID: spaceID)
        }
    }

    // MARK: - Private helpers

    @discardableResult
    static func findCmdNMenuItem(
        pid: pid_t,
        handler: (_ menuItem: AXUIElement, _ menuBarItem: AXUIElement) -> Bool?
    ) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)

        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarItems = axChildren(of: menuBarRef as! AXUIElement) else { return false }

        for menuBarItem in menuBarItems {
            guard let submenus = axChildren(of: menuBarItem),
                  let submenu = submenus.first,
                  let menuItems = axChildren(of: submenu) else { continue }

            for menuItem in menuItems {
                var cmdCharRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(menuItem, kAXMenuItemCmdCharAttribute as CFString, &cmdCharRef) == .success,
                      (cmdCharRef as? String) == "N" else { continue }

                var modifiersRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(menuItem, kAXMenuItemCmdModifiersAttribute as CFString, &modifiersRef) == .success,
                      (modifiersRef as? Int) == 0 else { continue }

                var enabledRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(menuItem, kAXEnabledAttribute as CFString, &enabledRef) == .success,
                      (enabledRef as? Bool) == true else { continue }

                if let result = handler(menuItem, menuBarItem) {
                    return result
                }
            }
        }
        return false
    }

    static func axChildren(of element: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success else { return nil }
        return ref as? [AXUIElement]
    }
}
