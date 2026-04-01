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
