import Foundation
import CoreGraphics
import ApplicationServices

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> UInt32

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: UInt32) -> CFArray

@_silgen_name("CGSManagedDisplayGetCurrentSpace")
func CGSManagedDisplayGetCurrentSpace(_ cid: UInt32, _ display: CFString) -> UInt64

/// Returns the type of a space:
///   0 = user desktop, 1 = fullscreen/overlay, 2 = system, 4 = tiled
@_silgen_name("CGSSpaceGetType")
func CGSSpaceGetType(_ cid: UInt32, _ sid: UInt64) -> Int32

/// Returns the spaces a window belongs to.
/// mask: 0x7 = all spaces, 0x1 = visible spaces
@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: UInt32, _ mask: Int32, _ windowIDs: CFArray) -> CFArray?

/// Returns the CGWindowID for an AXUIElement window.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Resolve the current space ID on the main display, using UUID-based lookup with "Main" fallback.
func CGSCurrentSpaceID() -> UInt64 {
    let cid = CGSMainConnectionID()
    let mainDisplayID = CGMainDisplayID()
    if let uuid = CGDisplayCreateUUIDFromDisplayID(mainDisplayID),
       let uuidString = CFUUIDCreateString(nil, uuid.takeRetainedValue()) {
        return CGSManagedDisplayGetCurrentSpace(cid, uuidString as CFString)
    }
    return CGSManagedDisplayGetCurrentSpace(cid, "Main" as CFString)
}

/// Enumerate AX windows of an app that exist on the current space.
/// - Parameters:
///   - pid: The process ID
///   - singleSpaceOnly: If true, skips windows assigned to multiple spaces (sticky windows)
///   - body: Called for each matching window. Return `true` to stop early.
func forEachWindowOnCurrentSpace(
    pid: pid_t,
    singleSpaceOnly: Bool = false,
    body: (_ appElement: AXUIElement, _ axWindow: AXUIElement, _ wid: CGWindowID) -> Bool
) {
    let appElement = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let axWindows = windowsRef as? [AXUIElement] else { return }

    let cid = CGSMainConnectionID()
    let currentSpaceID = CGSCurrentSpaceID()

    for axWindow in axWindows {
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(axWindow, &wid) == .success else { continue }

        guard let spaces = CGSCopySpacesForWindows(cid, 0x7, [wid] as CFArray) as? [UInt64],
              spaces.contains(currentSpaceID),
              !singleSpaceOnly || spaces.count == 1
        else { continue }

        if body(appElement, axWindow, wid) { return }
    }
}
