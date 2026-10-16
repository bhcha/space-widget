import AppKit
import SwiftUI

/// Nonactivating FIFO. Clicking and the temporary global shortcut share one action.
@MainActor
final class AgentToastPresenter {
    static let shared = AgentToastPresenter()
    static let maximumPending = 128
    private(set) var panel: NSPanel?
    private(set) var currentNotice: AgentCompletionNotice?
    private(set) var pending: [AgentCompletionNotice] = []
    private var dismissal: Task<Void, Never>?
    private var activating: UUID?
    private let navigation: AgentOriginNavigation
    private let shortcut: AgentToastShortcut
    private let displayDuration: Duration

    init(navigation: AgentOriginNavigation? = nil, displayDuration: Duration = .seconds(10),
         shortcut: AgentToastShortcut? = nil) {
        self.navigation = navigation ?? .shared
        self.shortcut = shortcut ?? .shared
        self.displayDuration = displayDuration
    }

    func activateCurrent() async {
        guard let notice = currentNotice else { return }
        await activate(notice)
    }

    func activate(_ notice: AgentCompletionNotice) async {
        guard let destination = notice.destination, currentNotice?.id == notice.id,
              activating == nil else { return }
        activating = notice.id
        dismissal?.cancel()
        // Keep the transient override until this toast is dismissed, so a second
        // press during activation cannot fall through to a window shortcut.
        panel?.orderOut(nil)
        let navigated = await navigation.navigate(to: destination)
        activating = nil
        guard currentNotice?.id == notice.id else { return }
        if navigated { dismissCurrent(expectedID: notice.id) }
        else {
            display(AgentCompletionNotice(event: notice.event, space: notice.space, isTest: false,
                origin: notice.origin, navigationIssue: "Could not reach the task's Space. Check Accessibility and Mission Control settings."))
        }
    }

    static func playSound() { NSSound(named: "Glass")?.play() }

    func show(_ notice: AgentCompletionNotice) {
        if currentNotice != nil {
            if pending.count == Self.maximumPending { pending.removeFirst() }
            pending.append(notice)
        } else { display(notice) }
    }

    func clear() {
        dismissal?.cancel()
        currentNotice = nil
        pending.removeAll()
        panel?.orderOut(nil)
        shortcut.configure(available: false)
    }

    func dismissCurrent(expectedID: UUID? = nil) {
        guard let currentNotice, expectedID == nil || expectedID == currentNotice.id else { return }
        dismissal?.cancel()
        self.currentNotice = nil
        panel?.orderOut(nil)
        shortcut.configure(available: false)
        if !pending.isEmpty { display(pending.removeFirst()) }
    }

    private func display(_ notice: AgentCompletionNotice) {
        dismissal?.cancel()
        panel?.orderOut(nil)
        currentNotice = notice
        shortcut.configure(available: notice.destination != nil) { [weak self] in
            Task { @MainActor in await self?.activate(notice) }
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 170),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: AgentToastView(notice: notice, shortcut: shortcut, navigate: { [weak self] in
            Task { @MainActor in await self?.activate(notice) }
        }, dismiss: { [weak self] in self?.dismissCurrent(expectedID: notice.id) }))
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 410, y: frame.maxY - 190))
        }
        self.panel = panel
        panel.orderFrontRegardless()
        let duration = displayDuration
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismissCurrent(expectedID: notice.id)
        }
    }
}

private struct AgentToastView: View {
    let notice: AgentCompletionNotice
    @ObservedObject var shortcut: AgentToastShortcut
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
                        if shortcut.registered { Text(shortcut.binding.displayString).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                    }.font(.caption)
                } else {
                    Text(notice.isTest ? "Notification preview" : "The task's Space could not be identified.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss notification")
        }.padding(18).frame(width: 390, height: 170, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
