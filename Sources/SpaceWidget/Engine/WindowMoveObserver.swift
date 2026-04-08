import AppKit
import ApplicationServices

/// Observes window move/resize events across all regular apps using AXObserver.
/// When a window is moved (potentially between displays), triggers a refresh callback.
final class WindowMoveObserver {
    private var observers: [pid_t: (observer: AXObserver, apps: Set<String>)] = [:]
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.2  // 200ms
    var onWindowMoved: (() -> Void)?

    init() {
        registerExistingApps()
        observeAppLifecycle()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        removeAllObservers()
    }

    // MARK: - App Lifecycle

    private func observeAppLifecycle() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else { return }
        // Delay registration to allow the app to create windows
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.registerApp(pid: app.processIdentifier)
        }
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        removeObserver(for: app.processIdentifier)
    }

    // MARK: - Registration

    private func registerExistingApps() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            registerApp(pid: app.processIdentifier)
        }
    }

    private func registerApp(pid: pid_t) {
        // Remove existing observer if re-registering (e.g. after new window created)
        let isReregistration = observers[pid] != nil
        if isReregistration {
            removeObserver(for: pid)
        }

        var observer: AXObserver?
        let result = AXObserverCreate(pid, { (_, element, notificationName, refcon) in
            guard let refcon = refcon else { return }
            let this = Unmanaged<WindowMoveObserver>.fromOpaque(refcon).takeUnretainedValue()
            let name = notificationName as String
            if name == kAXWindowCreatedNotification as String {
                // New window created — re-register to pick up move/resize on it
                var pidValue: pid_t = 0
                AXUIElementGetPid(element, &pidValue)
                this.handleWindowCreated(pid: pidValue)
            } else {
                this.handleWindowEvent()
            }
        }, &observer)

        guard result == .success, let observer = observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // kAXWindowCreatedNotification is app-level — register on app element
        AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, selfPtr)

        // kAXMovedNotification and kAXResizedNotification are window-level —
        // must register on each window element
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let axWindows = windowsRef as? [AXUIElement] {
            for axWindow in axWindows {
                AXObserverAddNotification(observer, axWindow, kAXMovedNotification as CFString, selfPtr)
                AXObserverAddNotification(observer, axWindow, kAXResizedNotification as CFString, selfPtr)
            }
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        observers[pid] = (observer: observer, apps: [])
    }

    private func removeObserver(for pid: pid_t) {
        guard let entry = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .defaultMode)
    }

    private func removeAllObservers() {
        for pid in Array(observers.keys) {
            removeObserver(for: pid)
        }
    }

    // MARK: - Event Handling

    private func handleWindowCreated(pid: pid_t) {
        // Re-register to attach move/resize observers to the new window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.registerApp(pid: pid)
            self?.handleWindowEvent()
        }
    }

    private func handleWindowEvent() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onWindowMoved?()
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
