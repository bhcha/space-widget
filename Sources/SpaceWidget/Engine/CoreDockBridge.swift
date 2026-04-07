import Foundation

/// Bridge to CoreDock private framework for flicker-free Dock control.
final class CoreDockBridge {
    typealias GetBool = @convention(c) () -> Bool
    typealias SetBool = @convention(c) (Bool) -> Void

    let getAutoHideEnabled: GetBool
    let setAutoHideEnabled: SetBool

    private let handle: UnsafeMutableRawPointer

    init?() {
        guard let h = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            RTLD_LAZY
        ) else { return nil }
        self.handle = h

        guard let gAH = dlsym(h, "CoreDockGetAutoHideEnabled"),
              let sAH = dlsym(h, "CoreDockSetAutoHideEnabled")
        else { dlclose(h); return nil }

        self.getAutoHideEnabled = unsafeBitCast(gAH, to: GetBool.self)
        self.setAutoHideEnabled = unsafeBitCast(sAH, to: SetBool.self)
    }

    deinit { dlclose(handle) }
}
