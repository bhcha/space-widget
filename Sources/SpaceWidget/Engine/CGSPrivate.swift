import Foundation
import CoreGraphics

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
