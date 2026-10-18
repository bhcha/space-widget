import AppKit
import QuartzCore
import SwiftUI

/// Lives in the widget's existing, display-sized panel. It never owns a window,
/// activates an application, or participates in hit testing.
final class SpaceLabelOverlay: NSView {
    static let bubbleSize = CGSize(width: 380, height: 62)
    static let holdDuration: TimeInterval = 2
    static let entranceDuration: TimeInterval = 0.30
    static let returnDuration: TimeInterval = 0.25
    private let bubble = CALayer()
    private let shape = CAShapeLayer()
    private let title = CATextLayer()
    private let icon = SpaceStackIcon()
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
        title.alignmentMode = .left
        title.truncationMode = .end
        title.isWrapped = false
        bubble.addSublayer(title)
        // Same left column as a notification card's state dot.
        icon.frame = CGRect(x: 14, y: (Self.bubbleSize.height - SpaceStackIcon.size) / 2,
                            width: SpaceStackIcon.size, height: SpaceStackIcon.size)
        bubble.addSublayer(icon)
        title.frame = CGRect(x: 62, y: 19, width: Self.bubbleSize.width - 62 - 20, height: 24)
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
        // The destination layer rises onto the stack as the bubble settles.
        let iconDelay = phase == "new" ? revealDelay + Self.entranceDuration * 0.6 : 0
        icon.play(number: ordinal, reduceMotion: reduceMotion, delay: iconDelay)

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
        shape.contentsScale = scale
        icon.setContentsScale(scale)
        // The Space number lives on the icon; the text is the name alone.
        title.string = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 19, weight: .medium), .foregroundColor: NSColor.white
        ])
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

/// The app icon's layer stack. On each Space change the bottom layer slides out to the
/// side, comes to the front, and settles on top of the stack showing the Space number,
/// while the other layers step down.
final class SpaceStackIcon: CALayer {
    static let size: CGFloat = 36
    static let slots: [CGFloat] = [11.7, 18, 24.3] // bottom, middle, top centers (y up)
    static let slideDuration: CFTimeInterval = 0.17
    static let riseDuration: CFTimeInterval = 0.28
    private(set) var order: [CAShapeLayer] = []
    private var numbers: [CAShapeLayer: CATextLayer] = [:]

    override init() {
        super.init()
        bounds = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        for slot in 0..<3 {
            let diamond = CAShapeLayer()
            diamond.bounds = CGRect(x: 0, y: 0, width: 27, height: 14.4)
            let path = CGMutablePath()
            path.addLines(between: [CGPoint(x: 0, y: 7.2), CGPoint(x: 13.5, y: 0),
                                    CGPoint(x: 27, y: 7.2), CGPoint(x: 13.5, y: 14.4)])
            path.closeSubpath()
            diamond.path = path
            diamond.fillColor = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor
            diamond.lineWidth = 2
            diamond.lineJoin = .round
            let number = CATextLayer()
            number.alignmentMode = .center
            number.frame = CGRect(x: 0, y: 1, width: 27, height: 14)
            // Lay the digit flat on the diamond's face.
            number.transform = CATransform3DMakeScale(1, 0.62, 1)
            diamond.addSublayer(number)
            numbers[diamond] = number
            addSublayer(diamond)
            order.append(diamond)
            place(diamond, slot: slot)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setContentsScale(_ scale: CGFloat) {
        for diamond in order {
            diamond.contentsScale = scale
            numbers[diamond]?.contentsScale = scale
        }
    }

    /// Number shown on the top layer.
    var topNumber: String? { (order.last.flatMap { numbers[$0]?.string } as? NSAttributedString)?.string }

    func play(number: Int, reduceMotion: Bool, delay: CFTimeInterval) {
        let rising = order[0], rest = Array(order.dropFirst())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        numbers[rising]?.string = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white
        ])
        order = rest + [rising]
        // Keep sibling order in step with the stack too; zPosition alone is ignored
        // by snapshots that render the layer tree.
        for diamond in order { addSublayer(diamond) }
        for (slot, diamond) in order.enumerated() {
            diamond.removeAllAnimations()
            numbers[diamond]?.removeAllAnimations()
            place(diamond, slot: slot)
        }
        CATransaction.commit()
        guard !reduceMotion else { return }
        let start = convertTime(CACurrentMediaTime(), from: nil) + delay
        let total = Self.slideDuration + Self.riseDuration
        let split = Self.slideDuration / total
        let bottom = CGPoint(x: Self.size / 2, y: Self.slots[0])
        let out = CGPoint(x: Self.size / 2 + 13.5, y: Self.slots[0])
        let top = CGPoint(x: Self.size / 2, y: Self.slots[2])
        let overshoot = CGPoint(x: Self.size / 2, y: Self.slots[2] + 1.6)
        let path = CAKeyframeAnimation(keyPath: "position")
        path.values = [bottom, out, overshoot, top].map { NSValue(point: $0) }
        path.keyTimes = [0, split, split + (1 - split) * 0.75, 1].map { NSNumber(value: $0) }
        path.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
                                CAMediaTimingFunction(name: .easeOut)]
        // Below the others while sliding out, in front once it rises.
        let depth = CAKeyframeAnimation(keyPath: "zPosition")
        depth.values = [-1, 3]
        depth.keyTimes = [0, NSNumber(value: split), 1]
        depth.calculationMode = .discrete
        let group = CAAnimationGroup()
        group.animations = [path, depth]
        group.beginTime = start
        group.duration = total
        group.fillMode = .backwards
        rising.add(group, forKey: "rise")
        for (slot, diamond) in rest.enumerated() {
            let step = CABasicAnimation(keyPath: "position")
            step.fromValue = NSValue(point: CGPoint(x: Self.size / 2, y: Self.slots[slot + 1]))
            step.beginTime = start + Self.slideDuration
            step.duration = Self.riseDuration * 0.8
            step.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            step.fillMode = .backwards
            diamond.add(step, forKey: "step")
        }
        for diamond in order {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = diamond === rising ? 0 : (numbers[diamond]?.presentation()?.opacity ?? 1)
            fade.beginTime = start + Self.slideDuration + 0.08
            fade.duration = 0.18
            fade.fillMode = .backwards
            numbers[diamond]?.add(fade, forKey: "fade")
        }
    }

    private func place(_ diamond: CAShapeLayer, slot: Int) {
        let isTop = slot == 2
        diamond.position = CGPoint(x: Self.size / 2, y: Self.slots[slot])
        diamond.zPosition = CGFloat(slot)
        diamond.strokeColor = NSColor.white.withAlphaComponent(isTop ? 1 : 0.45).cgColor
        numbers[diamond]?.opacity = isTop ? 1 : 0
    }
}
