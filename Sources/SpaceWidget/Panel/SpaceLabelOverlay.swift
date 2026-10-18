import AppKit
import QuartzCore
import SwiftUI

/// Lives in the widget's existing, display-sized panel. It never owns a window,
/// activates an application, or participates in hit testing.
final class SpaceLabelOverlay: NSView {
    static let bubbleSize = CGSize(width: 238, height: 82)
    static let holdDuration: TimeInterval = 2
    static let entranceDuration: TimeInterval = 0.30
    static let returnDuration: TimeInterval = 0.25
    private let bubble = CALayer()
    private let shape = CAShapeLayer()
    private let title = CATextLayer()
    private let subtitle = CATextLayer()
    private let clock: () -> CFTimeInterval
    private var flight: Flight?
    private var dismissWork: DispatchWorkItem?
    private var finishWork: DispatchWorkItem?
    private(set) var dismissAt: CFTimeInterval?
    private var reduceMotion = false
    private(set) var presentationID: UUID?
    var isPresenting: Bool { presentationID != nil }
    var onVisibilityChanged: (() -> Void)?

    override convenience init(frame: NSRect) {
        self.init(frame: frame, clock: CACurrentMediaTime)
    }

    init(frame: NSRect, clock: @escaping () -> CFTimeInterval) {
        self.clock = clock
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        isHidden = true
        bubble.bounds = CGRect(origin: .zero, size: Self.bubbleSize)
        bubble.shadowColor = NSColor.black.cgColor
        bubble.shadowOpacity = 0.22
        bubble.shadowRadius = 14
        bubble.shadowOffset = CGSize(width: 0, height: -5)
        shape.frame = bubble.bounds
        shape.fillColor = NSColor(calibratedWhite: 0.14, alpha: 0.96).cgColor
        shape.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
        shape.lineWidth = 0.7
        shape.path = Self.dropletPath(tail: 0)
        bubble.addSublayer(shape)
        for text in [title, subtitle] {
            text.alignmentMode = .center
            text.truncationMode = .end
            text.isWrapped = false
            bubble.addSublayer(text)
        }
        title.frame = CGRect(x: 18, y: 36, width: 202, height: 31)
        subtitle.frame = CGRect(x: 18, y: 18, width: 202, height: 16)
        layer?.addSublayer(bubble)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    deinit {
        dismissWork?.cancel()
        finishWork?.cancel()
    }

    /// Shares the exact fixed label slot geometry with SpaceBarView.
    static var widgetAnchor: CGPoint {
        CGPoint(x: SpaceBarConstants.leftPadding + SpaceBarConstants.horizontalPadding
                    + SpaceBarConstants.spaceNumberWidth + SpaceBarConstants.sectionSpacing
                    + SpaceBarConstants.labelWidth / 2,
                y: SpaceBarConstants.bottomPadding + SpaceBarConstants.barHeight / 2)
    }

    static func destination(in bounds: CGRect, visibleFrame: CGRect) -> CGPoint {
        let half = bubbleSize.height / 2
        return CGPoint(x: bounds.midX,
                       y: max(half + 8, min(bounds.height * 0.77, visibleFrame.maxY - half - 16)))
    }

    func show(name: String, ordinal: Int, visibleFrame: CGRect,
              reduceMotion: Bool, revealDelay: TimeInterval = 0) {
        let wasPresenting = isPresenting
        let now = clock()
        let destination = Self.destination(in: bounds, visibleFrame: visibleFrame)
        let expanded = Frame(position: destination, scale: 1, opacity: 1, tail: 0)
        let id = UUID()
        dismissWork?.cancel()
        finishWork?.cancel()
        finishWork = nil
        presentationID = id
        self.reduceMotion = reduceMotion

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateText(name: name, ordinal: ordinal)
        isHidden = false
        let phase: String
        if reduceMotion {
            stopFlight(at: expanded)
            phase = "static"
        } else if wasPresenting, let previous = flight, previous.kind == .entrance,
                  now < previous.endsAt {
            // Leave the existing ascent untouched. Only text and the idle timer change.
            phase = "continue-ascent"
        } else if wasPresenting, let previous = flight, previous.kind == .returning,
                  now < previous.endsAt {
            // Redirect the same bubble, carrying its position AND velocity.
            // A fresh ease-out here would abruptly reverse the falling bubble.
            let current = previous.sample(at: now - previous.startedAt)
            let velocity = previous.velocity(at: now - previous.startedAt)
            animateRecovery(from: current, velocity: velocity, to: expanded, now: now)
            phase = "redirect"
        } else if wasPresenting, flight?.kind != .returning {
            stopFlight(at: expanded)
            phase = "reuse-held"
        } else {
            let start = Frame(position: Self.widgetAnchor, scale: 0.34, opacity: 0, tail: 0)
            animateEntrance(from: start, to: expanded, now: now, duration: Self.entranceDuration,
                            revealDelay: revealDelay, stretch: true)
            phase = "new"
        }
        CATransaction.commit()

        // The return is scheduled independently of the entrance. Every Space
        // change earns a fresh readable hold; an old return cannot remain queued.
        let arrival = flight.flatMap { $0.kind == .entrance ? $0.endsAt : nil } ?? now
        let deadline = max(now, arrival) + Self.holdDuration
        dismissAt = deadline
        let work = DispatchWorkItem { [weak self] in self?.dismissIfDue(id) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (deadline - now), execute: work)
        swLog("SPACELABEL", "animation=\(phase) ordinal=\(ordinal) hold=\(Self.holdDuration)s")
        if !wasPresenting { onVisibilityChanged?() }
    }

    private func updateText(name: String, ordinal: Int) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty || trimmed == "Untitled" ? "Space \(ordinal)" : trimmed
        let scale = window?.backingScaleFactor ?? 2
        title.contentsScale = scale
        subtitle.contentsScale = scale
        shape.contentsScale = scale
        title.string = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 24, weight: .medium), .foregroundColor: NSColor.white
        ])
        subtitle.string = label == "Space \(ordinal)" ? nil : NSAttributedString(string: "Space \(ordinal)", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white.withAlphaComponent(0.65)
        ])
        title.frame.origin.y = label == "Space \(ordinal)" ? 26 : 36
    }

    /// Generation and deadline checks reject old queued callbacks after a switch.
    func dismissIfDue(_ id: UUID) {
        guard presentationID == id, let dismissAt, clock() >= dismissAt else { return }
        self.dismissAt = nil
        dismissWork = nil
        if reduceMotion {
            finish(id)
            return
        }
        let now = clock()
        let destination = bubble.position
        let frames = (0...60).map { index -> Frame in
            let t = CGFloat(index) / 60
            // Arrive at the widget with zero velocity. Accelerating all the way
            // into the anchor leaves a late interruption with enough momentum
            // to carry the bubble offscreen before a spring can turn it around.
            let progress = 1 - t * t * (3 - 2 * t)
            let smooth = progress * progress * (3 - 2 * progress)
            return Frame(position: Self.curve(from: Self.widgetAnchor, to: destination, progress: progress),
                         scale: 0.34 + 0.66 * smooth,
                         opacity: Float(min(1, max(0, (1 - t) / 0.15))),
                         tail: sin(.pi * t) * 1.05)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        animate(frames: frames, now: now, duration: Self.returnDuration, kind: .returning)
        CATransaction.commit()
        let work = DispatchWorkItem { [weak self] in self?.finish(id) }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.returnDuration, execute: work)
        swLog("SPACELABEL", "animation=return")
    }

    private func animateEntrance(from start: Frame, to end: Frame, now: CFTimeInterval,
                                 duration: TimeInterval, revealDelay: TimeInterval, stretch: Bool) {
        let total = revealDelay + duration
        let frames = (0...60).map { index -> Frame in
            let time = total * Double(index) / 60
            guard time >= revealDelay else { return start }
            let t = CGFloat(min(1, (time - revealDelay) / duration))
            let progress = 1 - pow(1 - t, 3)
            let smooth = progress * progress * (3 - 2 * progress)
            return Frame(position: Self.curve(from: start.position, to: end.position, progress: progress),
                         scale: start.scale + (1 - start.scale) * smooth,
                         opacity: start.opacity + (1 - start.opacity) * Float(min(1, t / 0.1)),
                         tail: start.tail * (1 - progress) + (stretch ? sin(.pi * t) * 0.9 : 0))
        }
        animate(frames: frames, now: now, duration: total, kind: .entrance)
    }

    private func animateRecovery(from start: Frame, velocity: Velocity, to end: Frame,
                                 now: CFTimeInterval) {
        // Apple's macOS 14 spring solver supplies a critically damped trajectory.
        // Keep the existing layer/keyframe renderer; no display link or new view.
        let spring = Spring(duration: 0.16, bounce: 0)
        let dx = end.position.x - start.position.x
        let dy = end.position.y - start.position.y
        let ds = end.scale - start.scale
        let duration = max(spring.settlingDuration,
            spring.settlingDuration(target: dx, initialVelocity: velocity.position.x, epsilon: 0.1),
            spring.settlingDuration(target: dy, initialVelocity: velocity.position.y, epsilon: 0.1),
            spring.settlingDuration(target: ds, initialVelocity: velocity.scale, epsilon: 0.0001))
        // Sample more densely near interruption, where braking changes velocity
        // fastest. Uniform keyframes would lose that velocity in the first step.
        let keyTimes = (0...120).map { pow(Double($0) / 120, 2) }
        let frames = keyTimes.enumerated().map { index, progress -> Frame in
            if index == 0 { return start }
            if index == 120 { return end } // Remaining error is below a visible pixel.
            let time = duration * progress
            let relaxation = CGFloat(spring.value(target: 1.0, time: time))
            return Frame(
                position: CGPoint(
                    x: start.position.x + spring.value(target: dx, initialVelocity: velocity.position.x, time: time),
                    y: start.position.y + spring.value(target: dy, initialVelocity: velocity.position.y, time: time)),
                scale: start.scale + spring.value(target: ds, initialVelocity: velocity.scale, time: time),
                // Reverse the fade immediately so a late interruption cannot
                // disappear while its movement is decelerating. Relax the tail
                // monotonically instead of adding another droplet kick.
                opacity: start.opacity + (end.opacity - start.opacity) * Float(relaxation),
                tail: start.tail * (1 - relaxation))
        }
        animate(frames: frames, now: now, duration: duration, kind: .entrance, keyTimes: keyTimes)
    }

    private func animate(frames: [Frame], now: CFTimeInterval, duration: TimeInterval, kind: Flight.Kind,
                         keyTimes: [Double]? = nil) {
        stopFlight(at: frames.last!)
        let times = keyTimes ?? frames.indices.map { Double($0) / Double(frames.count - 1) }
        flight = Flight(startedAt: now, duration: duration, kind: kind, frames: frames, keyTimes: times)
        let animations = [
            Self.keyframes("position", values: frames.map { NSValue(point: $0.position) }),
            Self.keyframes("transform.scale", values: frames.map { NSNumber(value: Double($0.scale)) }),
            Self.keyframes("opacity", values: frames.map { NSNumber(value: $0.opacity) })
        ]
        let group = CAAnimationGroup()
        group.animations = animations
        group.beginTime = bubble.convertTime(now, from: nil)
        group.duration = duration
        animations.forEach {
            $0.duration = duration
            $0.keyTimes = times.map { NSNumber(value: $0) }
        }
        bubble.add(group, forKey: "spaceLabelFlight")
        let morph = Self.keyframes("path", values: frames.map { Self.dropletPath(tail: $0.tail) })
        morph.beginTime = shape.convertTime(now, from: nil)
        morph.duration = duration
        morph.keyTimes = times.map { NSNumber(value: $0) }
        shape.add(morph, forKey: "spaceLabelDroplet")
    }

    private func stopFlight(at frame: Frame) {
        flight = nil
        bubble.removeAllAnimations()
        shape.removeAllAnimations()
        bubble.position = frame.position
        bubble.transform = CATransform3DMakeScale(frame.scale, frame.scale, 1)
        bubble.opacity = frame.opacity
        shape.path = Self.dropletPath(tail: frame.tail)
    }

    /// Generation check also protects a replacement from an already-enqueued callback.
    func finish(_ id: UUID) {
        guard presentationID == id else { return }
        cancel()
    }

    func cancel() {
        let wasPresenting = isPresenting
        dismissWork?.cancel()
        dismissWork = nil
        dismissAt = nil
        finishWork?.cancel()
        finishWork = nil
        presentationID = nil
        flight = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubble.removeAllAnimations()
        shape.removeAllAnimations()
        isHidden = true
        CATransaction.commit()
        if wasPresenting { onVisibilityChanged?() }
    }

    private static func keyframes(_ key: String, values: [Any]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values
        animation.calculationMode = .linear
        return animation
    }

    private struct Frame {
        var position: CGPoint
        var scale: CGFloat
        var opacity: Float
        var tail: CGFloat
    }

    private struct Velocity {
        var position: CGPoint
        var scale: CGFloat
    }

    /// Retain the submitted keyframes and their clock, rather than relying on a
    /// presentation layer that can be unavailable during a desktop transition.
    private struct Flight {
        enum Kind { case entrance, returning }
        let startedAt: CFTimeInterval
        let duration: TimeInterval
        let kind: Kind
        let frames: [Frame]
        let keyTimes: [Double]
        var endsAt: CFTimeInterval { startedAt + duration }

        func sample(at time: TimeInterval) -> Frame {
            let progress = min(1, max(0, time / duration))
            let lower = segment(at: progress), upper = lower + 1
            let t = CGFloat((progress - keyTimes[lower]) / (keyTimes[upper] - keyTimes[lower]))
            let a = frames[lower], b = frames[upper]
            return Frame(position: CGPoint(x: a.position.x + (b.position.x - a.position.x) * t,
                                           y: a.position.y + (b.position.y - a.position.y) * t),
                         scale: a.scale + (b.scale - a.scale) * t,
                         opacity: a.opacity + (b.opacity - a.opacity) * Float(t),
                         tail: a.tail + (b.tail - a.tail) * t)
        }

        func velocity(at time: TimeInterval) -> Velocity {
            guard time >= 0, time < duration else {
                return Velocity(position: .zero, scale: 0)
            }
            // Match the linear interpolation actually submitted to Core Animation.
            let lower = segment(at: time / duration)
            let step = duration * (keyTimes[lower + 1] - keyTimes[lower])
            let a = frames[lower], b = frames[lower + 1]
            return Velocity(position: CGPoint(x: (b.position.x - a.position.x) / step,
                                               y: (b.position.y - a.position.y) / step),
                            scale: (b.scale - a.scale) / step)
        }

        private func segment(at progress: Double) -> Int {
            min(keyTimes.lastIndex { $0 <= progress } ?? 0, frames.count - 2)
        }
    }

    static func curve(from a: CGPoint, to b: CGPoint, progress t: CGFloat) -> CGPoint {
        let control = CGPoint(x: a.x + (b.x - a.x) * 0.56, y: a.y + (b.y - a.y) * 0.74)
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * control.x + t * t * b.x,
                       y: u * u * a.y + 2 * u * t * control.y + t * t * b.y)
    }

    static func dropletPath(tail: CGFloat) -> CGPath {
        let radius = bubbleSize.height / 2
        let right = bubbleSize.width - radius
        let quarterControl = radius * 4 / 3 * tan(CGFloat.pi / 8)
        let halfControl = radius * 4 / 3 * tan(CGFloat.pi / 16)
        let diagonal = radius / sqrt(2)
        // Split the lower-left circular quadrant at 45 degrees. Moving the
        // point and both adjacent controls together stretches it into a tail;
        // at rest they form a smooth arc, with no residual dent or corner.
        let tip = CGPoint(x: radius - diagonal - tail * 24,
                          y: radius + diagonal + tail * 29)
        let tangent = halfControl / sqrt(2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: right, y: 0))
        path.addCurve(to: CGPoint(x: bubbleSize.width, y: radius),
                      control1: CGPoint(x: right + quarterControl, y: 0),
                      control2: CGPoint(x: bubbleSize.width, y: radius - quarterControl))
        path.addCurve(to: CGPoint(x: right, y: bubbleSize.height),
                      control1: CGPoint(x: bubbleSize.width, y: radius + quarterControl),
                      control2: CGPoint(x: right + quarterControl, y: bubbleSize.height))
        path.addLine(to: CGPoint(x: radius, y: bubbleSize.height))
        path.addCurve(to: tip, control1: CGPoint(x: radius - halfControl, y: bubbleSize.height),
                      control2: CGPoint(x: tip.x + tangent, y: tip.y + tangent))
        path.addCurve(to: CGPoint(x: 0, y: radius),
                      control1: CGPoint(x: tip.x - tangent, y: tip.y - tangent),
                      control2: CGPoint(x: 0, y: radius + halfControl))
        path.addCurve(to: CGPoint(x: radius, y: 0),
                      control1: CGPoint(x: 0, y: radius - quarterControl),
                      control2: CGPoint(x: radius - quarterControl, y: 0))
        path.closeSubpath()
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bubbleSize.height)
        return path.copy(using: &flip)!
    }
}
