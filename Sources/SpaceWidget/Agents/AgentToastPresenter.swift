import AppKit
import SwiftUI

/// Nonactivating deck of notification capsules at the Space label's anchor, newest in
/// front. Up to `maximumVisible` cards are shown; later arrivals wait in a bounded FIFO.
/// Each card keeps its own timer and destination, and any visible part of any card
/// navigates to that card's Space. The temporary global shortcut acts on the newest
/// navigable card. While the Space label is showing it is the front card of the same
/// deck: notification cards step back one card and their timers pause.
@MainActor
final class AgentToastPresenter {
    static let shared = AgentToastPresenter()
    static let maximumVisible = 3
    static let maximumPending = 128
    static let toastSize = SpaceLabelOverlay.bubbleSize
    /// How much of each card behind the front one stays visible.
    static let peek: CGFloat = 12
    /// Gap between cards when the deck is fanned out.
    static let spacing: CGFloat = 8
    static let depthScale: CGFloat = 0.05
    static let depthFade: Double = 0.18
    /// One level below the widget panel, so the Space label always draws in front.
    static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
    static let expandDelay: Duration = .milliseconds(600)
    static let minimumResume: Duration = .milliseconds(800)

    /// Newest first; index 0 is the front card.
    private(set) var visible: [AgentCompletionNotice] = []
    private(set) var pending: [AgentCompletionNotice] = []
    private(set) var isExpanded = false
    private(set) var spaceLabelInFront = false
    private var panels: [UUID: NSPanel] = [:]
    private var slotStates: [UUID: AgentToastSlotState] = [:]
    private var dismissals: [UUID: Task<Void, Never>] = [:]
    private var remaining: [UUID: Duration] = [:]
    private var deadlines: [UUID: ContinuousClock.Instant] = [:]
    private var hovered: Set<UUID> = []
    private var hoverTask: Task<Void, Never>?
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

    /// The front (newest) visible card.
    var currentNotice: AgentCompletionNotice? { visible.first }
    /// The front card's panel.
    var panel: NSPanel? { currentNotice.flatMap { panels[$0.id] } }
    func panel(for id: UUID) -> NSPanel? { panels[id] }
    /// The newest visible card that can navigate; the shortcut acts on it.
    var shortcutTarget: AgentCompletionNotice? { visible.first { $0.destination != nil } }
    /// Seconds of display time left for a card, while its timer is paused or running.
    func timeRemaining(for id: UUID) -> Duration? {
        if let deadline = deadlines[id] { return max(.zero, deadline - ContinuousClock.now) }
        return remaining[id]
    }

    /// The deck's anchor: the Space label's resting center on `screen`.
    static func anchor(screenFrame: NSRect, visibleFrame: NSRect) -> CGPoint {
        let local = visibleFrame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        let center = SpaceLabelOverlay.destination(in: CGRect(origin: .zero, size: screenFrame.size), visibleFrame: local)
        return CGPoint(x: screenFrame.minX + center.x, y: screenFrame.minY + center.y)
    }

    /// Panel frame of the card at `position` in the deck. Collapsed, each step back is
    /// `peek` lower (the card itself is drawn smaller from its top edge); fanned out,
    /// cards are listed `spacing` apart.
    static func frame(position: Int, expanded: Bool, anchor: CGPoint) -> NSRect {
        let step = expanded ? toastSize.height + spacing : peek
        // Whole points: the window server rounds panel origins anyway.
        return NSRect(x: (anchor.x - toastSize.width / 2).rounded(),
                      y: (anchor.y - toastSize.height / 2 - CGFloat(position) * step).rounded(),
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
        stopTimer(notice.id)
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
                origin: notice.origin, navigationIssue: "Check Accessibility and Mission Control settings.")
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
            layout(animated: false)
        } else { insertOnTop(notice) }
    }

    func clear() {
        for notice in visible { diagnostics.emit("toast.cleared", event: notice.event, fields: notice.diagnosticFields) }
        for id in visible.map(\.id) { removePanel(id) }
        visible.removeAll()
        pending.removeAll()
        hovered.removeAll()
        hoverTask?.cancel()
        isExpanded = false
        shortcut.configure(available: false)
    }

    /// Dismisses `expectedID` if it is visible, or the front card when no ID is given.
    func dismissCurrent(expectedID: UUID? = nil, reason: String = "dismiss") {
        guard let id = expectedID ?? currentNotice?.id else { return }
        dismiss(id, reason: reason)
    }

    /// The Space label started or stopped showing on the deck's display. While it is in
    /// front, cards step back one position and their timers pause so none expires unseen.
    func setSpaceLabelInFront(_ inFront: Bool) {
        guard inFront != spaceLabelInFront else { return }
        spaceLabelInFront = inFront
        for id in visible.map(\.id) { inFront ? pauseTimer(id) : startTimer(id) }
        layout(animated: true)
    }

    /// The active Space changed to `uuid` by any route. A finished task's card for that
    /// Space has nothing left to do, so it is dismissed.
    func spaceDidBecomeActive(uuid: String) {
        let arrived = visible.filter { $0.destination?.spaceUUID == uuid && $0.id != activating }
        for notice in arrived { dismiss(notice.id, reason: "arrived") }
    }

    /// Hover over any card fans the deck out after a short rest, so a quick click on a
    /// back card's edge still lands on that card.
    func hoverChanged(_ id: UUID, inside: Bool) {
        if inside { hovered.insert(id) } else { hovered.remove(id) }
        slotStates[id]?.hovering = inside
        hoverTask?.cancel()
        let wanted = !hovered.isEmpty
        guard wanted != isExpanded else { return }
        // Collapse after a brief grace period, so moving between cards does not flicker.
        let delay = wanted ? Self.expandDelay : .milliseconds(150)
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.setExpanded(wanted)
        }
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        layout(animated: true)
    }

    private func dismiss(_ id: UUID, reason: String) {
        guard let index = visible.firstIndex(where: { $0.id == id }) else { return }
        let notice = visible.remove(at: index)
        diagnostics.emit("toast.dismissed", event: notice.event, fields: notice.diagnosticFields.merging(["reason": reason]) { _, new in new })
        removePanel(id)
        if visible.isEmpty { isExpanded = false }
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
        panel.level = Self.windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let state = AgentToastSlotState()
        let id = notice.id
        let host = AgentToastHostingView(rootView: AgentToastView(notice: notice, shortcut: shortcut, slot: state, navigate: { [weak self] in
            Task { @MainActor in await self?.activate(notice) }
        }, dismiss: { [weak self] in self?.dismissCurrent(expectedID: id) }))
        host.onHover = { [weak self] inside in self?.hoverChanged(id, inside: inside) }
        panel.contentView = host
        if let anchor = deckAnchor() {
            // A new card appears directly in front; older ones step back.
            panel.setFrame(Self.frame(position: frontPosition, expanded: isExpanded, anchor: anchor), display: false)
        }
        panels[id] = panel
        slotStates[id] = state
        panel.orderFrontRegardless()
        remaining[id] = displayDuration
        if !spaceLabelInFront { startTimer(id) }
    }

    private func removePanel(_ id: UUID) {
        stopTimer(id)
        remaining.removeValue(forKey: id)
        hovered.remove(id)
        panels.removeValue(forKey: id)?.orderOut(nil)
        slotStates.removeValue(forKey: id)
    }

    private func startTimer(_ id: UUID) {
        guard dismissals[id] == nil, activating != id, let duration = remaining[id] else { return }
        deadlines[id] = ContinuousClock.now + duration
        dismissals[id] = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismissCurrent(expectedID: id, reason: "timeout")
        }
    }

    private func pauseTimer(_ id: UUID) {
        guard let deadline = deadlines.removeValue(forKey: id) else { return }
        dismissals.removeValue(forKey: id)?.cancel()
        remaining[id] = max(Self.minimumResume, deadline - ContinuousClock.now)
    }

    private func stopTimer(_ id: UUID) {
        dismissals.removeValue(forKey: id)?.cancel()
        deadlines.removeValue(forKey: id)
    }

    /// The Space label occupies the front position while it is showing.
    private var frontPosition: Int { spaceLabelInFront ? 1 : 0 }

    private func deckAnchor() -> CGPoint? {
        guard let screen = NSScreen.main else { return nil }
        return Self.anchor(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    private func layout(animated: Bool) {
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let anchor = deckAnchor()
        for (index, notice) in visible.enumerated() {
            let position = index + frontPosition
            if let state = slotStates[notice.id] {
                state.animates = animate
                state.depth = isExpanded ? 0 : position
                state.waiting = index == 0 ? pending.count : 0
            }
            guard let panel = panels[notice.id], let anchor else { continue }
            let target = Self.frame(position: position, expanded: isExpanded, anchor: anchor)
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
        // Back to front, so newer cards are drawn over older ones.
        for notice in visible.reversed() where notice.id != activating {
            panels[notice.id]?.orderFrontRegardless()
        }
    }

    private func refreshShortcut() {
        let target = shortcutTarget
        for notice in visible { slotStates[notice.id]?.isShortcutTarget = notice.id == target?.id }
        // While a card is navigating, keep the override registered even if no other
        // card can navigate, so a repeated press cannot reach a window shortcut.
        guard target != nil || activating != nil else { shortcut.configure(available: false); return }
        shortcut.configure(available: true) { [weak self] in
            guard let target else { return }
            Task { @MainActor in await self?.activate(target, input: "shortcut") }
        }
    }
}

/// Per-card presentation state that changes while the card is visible.
@MainActor
final class AgentToastSlotState: ObservableObject {
    @Published var isShortcutTarget = false
    /// 0 for the front card; each step back draws the card smaller and fainter.
    @Published var depth = 0
    /// Cards waiting behind the deck, shown on the front card.
    @Published var waiting = 0
    @Published var hovering = false
    var animates = true
}

/// Reports hover even while SpaceWidget is not the active app.
private final class AgentToastHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.userInfo?["deck"] != nil }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["deck": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// What a card says about its task, and its state color.
struct AgentToastAppearance: Equatable {
    enum Tone: Equatable { case done, warning, preview }
    let tone: Tone
    let state: String
    let detail: String

    init(_ notice: AgentCompletionNotice) {
        let source = [notice.event.agent?.name ?? notice.event.agentID, notice.event.application?.name]
            .compactMap { $0 }.joined(separator: " · ")
        if notice.isTest {
            self.init(tone: .preview, state: "Preview", detail: "Notification preview")
        } else if let issue = notice.navigationIssue {
            self.init(tone: .warning, state: "Couldn't go", detail: issue)
        } else if notice.destination == nil {
            self.init(tone: .warning, state: "Unknown Space", detail: source + " · Can't return to this task")
        } else {
            self.init(tone: .done, state: "Done", detail: notice.detail)
        }
    }

    private init(tone: Tone, state: String, detail: String) {
        self.tone = tone
        self.state = state
        self.detail = detail
    }
}

private struct AgentToastView: View {
    let notice: AgentCompletionNotice
    @ObservedObject var shortcut: AgentToastShortcut
    @ObservedObject var slot: AgentToastSlotState
    let navigate: () -> Void
    let dismiss: () -> Void

    private var appearance: AgentToastAppearance { AgentToastAppearance(notice) }
    private var color: Color {
        switch appearance.tone {
        case .done: return Color(nsColor: .systemGreen)
        case .warning: return Color(nsColor: .systemOrange)
        case .preview: return Color(nsColor: .systemGray)
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 10, height: 10)
                .overlay(Circle().stroke(color.opacity(0.22), lineWidth: 3).frame(width: 16, height: 16))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(notice.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(appearance.state).font(.system(size: 12, weight: .semibold)).foregroundColor(color)
                        .lineLimit(1).fixedSize()
                }
                Text(appearance.detail).font(.system(size: 11.5)).foregroundColor(.white.opacity(0.65)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    var body: some View {
        HStack(spacing: 8) {
            if notice.destination != nil {
                Button(action: navigate) { content }.buttonStyle(.plain)
                    .accessibilityLabel("\(notice.title), \(appearance.state). Go to the task's Space")
            } else {
                content
            }
            if slot.waiting > 0 {
                Text("+\(slot.waiting) more").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.7))
            }
            if shortcut.registered && slot.isShortcutTarget {
                Text(shortcut.binding.displayString).font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.28), lineWidth: 0.7))
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20).background(Circle().fill(.white.opacity(0.1)))
            }
            .buttonStyle(.plain).foregroundColor(.white.opacity(0.75))
            .opacity(slot.hovering ? 1 : 0)
            .accessibilityLabel("Dismiss notification")
        }
        .padding(.leading, 20).padding(.trailing, 14)
        .frame(width: AgentToastPresenter.toastSize.width, height: AgentToastPresenter.toastSize.height)
        .foregroundColor(.white)
        .background(Capsule().fill(Color(white: 0.14, opacity: 0.96)))
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.7))
        .environment(\.colorScheme, .dark)
        .scaleEffect(1 - CGFloat(slot.depth) * AgentToastPresenter.depthScale, anchor: .top)
        .opacity(slot.depth == 0 ? 1 : 1 - Double(slot.depth) * AgentToastPresenter.depthFade)
        .animation(slot.animates ? .easeOut(duration: 0.2) : nil, value: slot.depth)
    }
}
