import AppKit
import SwiftUI

/// Nonactivating stack, newest on top. Up to `maximumVisible` toasts are shown at once;
/// later arrivals wait in a bounded FIFO. Each toast keeps its own timer and destination.
/// Clicking acts on that toast; the temporary global shortcut acts on the newest navigable one.
@MainActor
final class AgentToastPresenter {
    static let shared = AgentToastPresenter()
    static let maximumVisible = 3
    static let maximumPending = 128
    static let toastSize = CGSize(width: 390, height: 170)
    static let spacing: CGFloat = 10
    static let margin: CGFloat = 20

    /// Newest first; index 0 is the top slot.
    private(set) var visible: [AgentCompletionNotice] = []
    private(set) var pending: [AgentCompletionNotice] = []
    private var panels: [UUID: NSPanel] = [:]
    private var slotStates: [UUID: AgentToastSlotState] = [:]
    private var dismissals: [UUID: Task<Void, Never>] = [:]
    private var activating: UUID?
    private let navigation: AgentOriginNavigation
    private let shortcut: AgentToastShortcut
    private let displayDuration: Duration
    private let diagnostics: HookDiagnostics

    init(navigation: AgentOriginNavigation? = nil, displayDuration: Duration = .seconds(10),
         shortcut: AgentToastShortcut? = nil, diagnostics: HookDiagnostics = .live) {
        self.navigation = navigation ?? .shared
        self.shortcut = shortcut ?? .shared
        self.displayDuration = displayDuration
        self.diagnostics = diagnostics
    }

    /// The top (newest) visible toast.
    var currentNotice: AgentCompletionNotice? { visible.first }
    /// The top toast's panel.
    var panel: NSPanel? { currentNotice.flatMap { panels[$0.id] } }
    func panel(for id: UUID) -> NSPanel? { panels[id] }
    /// The newest visible toast that can navigate; the shortcut acts on it.
    var shortcutTarget: AgentCompletionNotice? { visible.first { $0.destination != nil } }

    /// Frame of a stack slot, counted from the top-right corner of `visibleFrame`.
    static func frame(slot: Int, in visibleFrame: NSRect) -> NSRect {
        NSRect(x: visibleFrame.maxX - margin - toastSize.width,
               y: visibleFrame.maxY - margin - toastSize.height - CGFloat(slot) * (toastSize.height + spacing),
               width: toastSize.width, height: toastSize.height)
    }

    func activateCurrent() async {
        guard let notice = shortcutTarget else { return }
        await activate(notice)
    }

    func activate(_ notice: AgentCompletionNotice, input: String = "click") async {
        var fields = notice.diagnosticFields
        fields["input"] = input
        fields["visible_notice"] = currentNotice?.id.uuidString ?? "none"
        fields["visible_count"] = String(visible.count)
        let isVisible = visible.contains { $0.id == notice.id }
        guard let destination = notice.destination, isVisible, activating == nil else {
            fields["reason"] = notice.destination == nil ? "no_destination" : (!isVisible ? "stale_notice" : "already_activating")
            diagnostics.emit("toast.activation_ignored", event: notice.event, fields: fields)
            return
        }
        diagnostics.emit("toast.activated", event: notice.event, fields: fields)
        activating = notice.id
        dismissals.removeValue(forKey: notice.id)?.cancel()
        // Keep the transient override until activation ends, so a second
        // press during activation cannot fall through to a window shortcut.
        panels[notice.id]?.orderOut(nil)
        let navigated = await navigation.navigate(to: destination, event: notice.event, noticeID: notice.id)
        fields["success"] = String(navigated)
        diagnostics.emit("toast.navigation_finished", event: notice.event, fields: fields)
        activating = nil
        guard let index = visible.firstIndex(where: { $0.id == notice.id }) else { refreshShortcut(); return }
        if navigated { dismiss(notice.id, reason: "navigated") }
        else {
            let failed = AgentCompletionNotice(event: notice.event, space: notice.space, isTest: false,
                origin: notice.origin, navigationIssue: "Could not reach the task's Space. Check Accessibility and Mission Control settings.")
            removePanel(notice.id)
            visible[index] = failed
            diagnostics.emit("toast.displayed", event: failed.event, fields: failed.diagnosticFields.merging(["slot": String(index), "visible_count": String(visible.count)]) { _, new in new })
            present(failed)
            layout(animated: false)
            refreshShortcut()
        }
    }

    static func playSound() { NSSound(named: "Glass")?.play() }

    func show(_ notice: AgentCompletionNotice) {
        if visible.count >= Self.maximumVisible {
            if pending.count == Self.maximumPending {
                let dropped = pending.removeFirst()
                diagnostics.emit("toast.queue_dropped", event: dropped.event, fields: dropped.diagnosticFields)
            }
            pending.append(notice)
            diagnostics.emit("toast.queued", event: notice.event, fields: notice.diagnosticFields.merging(["queue_count": String(pending.count)]) { _, new in new })
        } else { insertOnTop(notice) }
    }

    func clear() {
        for notice in visible { diagnostics.emit("toast.cleared", event: notice.event, fields: notice.diagnosticFields) }
        for id in visible.map(\.id) { removePanel(id) }
        visible.removeAll()
        pending.removeAll()
        shortcut.configure(available: false)
    }

    /// Dismisses `expectedID` if it is visible, or the top toast when no ID is given.
    func dismissCurrent(expectedID: UUID? = nil, reason: String = "dismiss") {
        guard let id = expectedID ?? currentNotice?.id else { return }
        dismiss(id, reason: reason)
    }

    private func dismiss(_ id: UUID, reason: String) {
        guard let index = visible.firstIndex(where: { $0.id == id }) else { return }
        let notice = visible.remove(at: index)
        diagnostics.emit("toast.dismissed", event: notice.event, fields: notice.diagnosticFields.merging(["reason": reason]) { _, new in new })
        removePanel(id)
        if !pending.isEmpty {
            insertOnTop(pending.removeFirst())
        } else {
            layout(animated: true)
            refreshShortcut()
        }
    }

    private func insertOnTop(_ notice: AgentCompletionNotice) {
        visible.insert(notice, at: 0)
        diagnostics.emit("toast.displayed", event: notice.event, fields: notice.diagnosticFields.merging(["slot": "0", "visible_count": String(visible.count)]) { _, new in new })
        present(notice)
        layout(animated: true)
        refreshShortcut()
    }

    private func present(_ notice: AgentCompletionNotice) {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.toastSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let state = AgentToastSlotState()
        panel.contentView = NSHostingView(rootView: AgentToastView(notice: notice, shortcut: shortcut, slot: state, navigate: { [weak self] in
            Task { @MainActor in await self?.activate(notice) }
        }, dismiss: { [weak self] in self?.dismissCurrent(expectedID: notice.id) }))
        if let screen = NSScreen.main?.visibleFrame {
            // A new toast appears directly in the top slot; older ones slide down.
            panel.setFrame(Self.frame(slot: 0, in: screen), display: false)
        }
        panels[notice.id] = panel
        slotStates[notice.id] = state
        panel.orderFrontRegardless()
        let duration = displayDuration
        dismissals[notice.id] = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismissCurrent(expectedID: notice.id, reason: "timeout")
        }
    }

    private func removePanel(_ id: UUID) {
        dismissals.removeValue(forKey: id)?.cancel()
        panels.removeValue(forKey: id)?.orderOut(nil)
        slotStates.removeValue(forKey: id)
    }

    private func layout(animated: Bool) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (slot, notice) in visible.enumerated() {
            guard let panel = panels[notice.id] else { continue }
            let target = Self.frame(slot: slot, in: screen)
            guard panel.frame != target else { continue }
            if animate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(target, display: true)
                }
            } else {
                panel.setFrame(target, display: true)
            }
        }
    }

    private func refreshShortcut() {
        let target = shortcutTarget
        for notice in visible { slotStates[notice.id]?.isShortcutTarget = notice.id == target?.id }
        // While a toast is navigating, keep the override registered even if no other
        // toast can navigate, so a repeated press cannot reach a window shortcut.
        guard target != nil || activating != nil else { shortcut.configure(available: false); return }
        shortcut.configure(available: true) { [weak self] in
            guard let target else { return }
            Task { @MainActor in await self?.activate(target, input: "shortcut") }
        }
    }
}

/// Per-toast presentation state that changes while the toast is visible.
@MainActor
final class AgentToastSlotState: ObservableObject {
    @Published var isShortcutTarget = false
}

private struct AgentToastView: View {
    let notice: AgentCompletionNotice
    @ObservedObject var shortcut: AgentToastShortcut
    @ObservedObject var slot: AgentToastSlotState
    let navigate: () -> Void
    let dismiss: () -> Void
    private var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(notice.title).font(.headline).lineLimit(2)
            Text(notice.status).font(.subheadline)
            Text(notice.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(.blue).frame(width: 9, height: 9).padding(.top, 6)
            VStack(alignment: .leading, spacing: 7) {
                if notice.destination != nil {
                    Button(action: navigate) { content }.buttonStyle(.plain)
                } else {
                    content
                }
                if let issue = notice.navigationIssue {
                    Text(issue).font(.caption).foregroundStyle(.secondary)
                } else if notice.destination != nil {
                    HStack {
                        Button(notice.actionTitle, action: navigate)
                        if shortcut.registered && slot.isShortcutTarget { Text(shortcut.binding.displayString).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                    }.font(.caption)
                } else {
                    Text(notice.isTest ? "Notification preview" : "Could not determine the Space where this task started.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss notification")
        }.padding(18).frame(width: 390, height: 170, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
