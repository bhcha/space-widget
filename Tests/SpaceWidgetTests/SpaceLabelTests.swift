import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import SpaceWidget

final class SpaceLabelTests: XCTestCase {
    func testLaunchZeroIDAndDuplicateEventsDoNotNotify() {
        var tracker = SpaceLabelTransitionTracker()
        XCTAssertFalse(tracker.observe(.init(id: 0, ordinal: 1)))
        XCTAssertFalse(tracker.observe(.init(id: 10, ordinal: 1, uuid: "a")))
        XCTAssertFalse(tracker.observe(.init(id: 10, ordinal: 1, uuid: "a")))
        // A reordered ordinal, or refreshed runtime ID with the same UUID, is not a transition.
        XCTAssertFalse(tracker.observe(.init(id: 10, ordinal: 4, uuid: "a")))
        XCTAssertFalse(tracker.observe(.init(id: 11, ordinal: 4, uuid: "a")))
        XCTAssertTrue(tracker.observe(.init(id: 11, ordinal: 4, uuid: "b")))
    }

    func testUUIDArrivalAndMissingUUIDUseRuntimeIdentity() {
        var tracker = SpaceLabelTransitionTracker(initialSpace: .init(id: 10, ordinal: 1))
        XCTAssertFalse(tracker.observe(.init(id: 10, ordinal: 1, uuid: "a")))
        XCTAssertFalse(tracker.observe(.init(id: 10, ordinal: 1)))
        XCTAssertTrue(tracker.observe(.init(id: 20, ordinal: 1)))
    }

    func testFullscreenReturnToSameDesktopNotifiesOnce() {
        let space = ActiveSpace(id: 10, ordinal: 1, uuid: "a")
        var tracker = SpaceLabelTransitionTracker(initialSpace: space)
        XCTAssertFalse(tracker.observe(nil))
        XCTAssertFalse(tracker.observe(nil))
        XCTAssertTrue(tracker.observe(space))
        XCTAssertFalse(tracker.observe(space))
        var initialFullscreen = SpaceLabelTransitionTracker()
        XCTAssertFalse(initialFullscreen.observe(nil))
        XCTAssertFalse(initialFullscreen.observe(space))
    }

    func testDisplaysStayIndependentAndReconnectStartsWithBaseline() {
        var first = SpaceLabelTransitionTracker(initialSpace: .init(id: 10, ordinal: 1))
        var second = SpaceLabelTransitionTracker(initialSpace: .init(id: 20, ordinal: 1))
        XCTAssertTrue(first.observe(.init(id: 11, ordinal: 2)))
        XCTAssertFalse(second.observe(.init(id: 20, ordinal: 1)))
        second = SpaceLabelTransitionTracker()
        XCTAssertFalse(second.observe(.init(id: 21, ordinal: 2)))
        XCTAssertTrue(second.observe(.init(id: 22, ordinal: 3)))
    }

    func testDisabledPeriodCanAdvanceBaselineWithoutStaleReplay() {
        var tracker = SpaceLabelTransitionTracker(initialSpace: .init(id: 10, ordinal: 1))
        // The controller always consumes events, even when presentation is disabled.
        _ = tracker.observe(.init(id: 11, ordinal: 2))
        _ = tracker.observe(.init(id: 12, ordinal: 3))
        XCTAssertFalse(tracker.observe(.init(id: 12, ordinal: 3)))
        XCTAssertTrue(tracker.observe(.init(id: 10, ordinal: 1)))
    }

    func testPreferencePersistsAndDisabledPreviewDoesNotRun() throws {
        let suite = "SpaceLabelTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SpaceLabelSettings(defaults: defaults)
        XCTAssertTrue(settings.isEnabled)
        var calls = 0
        settings.onPreview = { calls += 1; return true }
        settings.isEnabled = false
        settings.preview()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(SpaceLabelSettings(defaults: defaults).isEnabled)
        settings.isEnabled = true
        settings.preview()
        XCTAssertEqual(calls, 1)
        XCTAssertNil(settings.previewIssue)
        settings.onPreview = { false }
        settings.preview()
        XCTAssertNotNil(settings.previewIssue)
    }

    @MainActor
    func testStaleCompletionCannotHideReplacementAndCancelCleansUp() throws {
        let overlay = SpaceLabelOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 676)
        var changes = 0
        overlay.onVisibilityChanged = { changes += 1 }
        overlay.show(name: "Work", ordinal: 1, visibleFrame: visible, reduceMotion: false)
        let first = try XCTUnwrap(overlay.presentationID)
        overlay.show(name: "Research", ordinal: 2, visibleFrame: visible, reduceMotion: false)
        let second = try XCTUnwrap(overlay.presentationID)
        overlay.finish(first)
        XCTAssertTrue(overlay.isPresenting)
        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(changes, 1, "A replacement must not briefly restore auto-hide")
        overlay.finish(second)
        XCTAssertFalse(overlay.isPresenting)
        XCTAssertTrue(overlay.isHidden)
        XCTAssertEqual(changes, 2)
        XCTAssertTrue(overlay.layer?.sublayers?.allSatisfy { $0.animationKeys() == nil } == true)
    }

    @MainActor
    func testEverySwitchResetsIdleTimerAndHeldLabelDoesNotMove() throws {
        var now = CACurrentMediaTime()
        let overlay = SpaceLabelOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 700), clock: { now })
        defer { overlay.cancel() }
        overlay.show(name: "Work", ordinal: 1, visibleFrame: overlay.bounds, reduceMotion: false)
        let bubble = try XCTUnwrap(overlay.layer?.sublayers?.first)
        let destination = SpaceLabelOverlay.destination(in: overlay.bounds, visibleFrame: overlay.bounds)
        // Repeated switches within the selected two-second hold must keep the
        // label still. Longer gaps may legitimately begin the return.
        for (index, gap) in [1.841, 1.714, 1.725, 1.969].enumerated() {
            let previousID = try XCTUnwrap(overlay.presentationID)
            now += gap
            overlay.show(name: "Project \(index)", ordinal: index + 2, visibleFrame: overlay.bounds, reduceMotion: false)
            let id = try XCTUnwrap(overlay.presentationID)
            XCTAssertEqual(try XCTUnwrap(overlay.dismissAt), now + 2, accuracy: 0.001)
            XCTAssertTrue(overlay.layer?.sublayers?.first === bubble)
            XCTAssertNil(bubble.animationKeys(), "A held label only changes text and its idle deadline")
            XCTAssertEqual(bubble.position, destination)
            XCTAssertEqual(bubble.opacity, 1)
            XCTAssertEqual(bubble.transform.m11, 1)
            overlay.dismissIfDue(previousID)
            overlay.finish(previousID)
            overlay.dismissIfDue(id) // Too early: the fresh 2-second hold is intact.
            XCTAssertTrue(overlay.isPresenting)
            XCTAssertNil(bubble.animationKeys())
        }
        let id = try XCTUnwrap(overlay.presentationID)
        now = try XCTUnwrap(overlay.dismissAt) - 0.001
        overlay.dismissIfDue(id)
        XCTAssertNil(bubble.animationKeys())
        now += 0.002
        overlay.dismissIfDue(id)
        let returning = try XCTUnwrap(bubble.animation(forKey: "spaceLabelFlight") as? CAAnimationGroup)
        XCTAssertEqual(returning.duration, 0.25, accuracy: 0.001)
        XCTAssertNil(overlay.dismissAt)
        overlay.dismissIfDue(id) // A duplicated callback must not restart the return.
        let sameReturn = try XCTUnwrap(bubble.animation(forKey: "spaceLabelFlight") as? CAAnimationGroup)
        XCTAssertEqual(sameReturn.beginTime, returning.beginTime)
        overlay.finish(id)
        XCTAssertFalse(overlay.isPresenting)
        XCTAssertTrue(overlay.isHidden)
    }

    @MainActor
    func testReplacementDuringRevealAndAscentLeavesOriginalAnimationUntouched() throws {
        var now = CACurrentMediaTime()
        let overlay = SpaceLabelOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 700), clock: { now })
        defer { overlay.cancel() }
        overlay.show(name: "Work", ordinal: 1, visibleFrame: overlay.bounds, reduceMotion: false, revealDelay: 0.25)
        let bubble = try XCTUnwrap(overlay.layer?.sublayers?.first)
        let original = try XCTUnwrap(bubble.animation(forKey: "spaceLabelFlight") as? CAAnimationGroup)
        XCTAssertEqual(original.duration, 0.55, accuracy: 0.001)
        for elapsed in [0.1, 0.4] {
            now = original.beginTime + elapsed
            overlay.show(name: "Research", ordinal: 2, visibleFrame: overlay.bounds, reduceMotion: false, revealDelay: 0.25)
            let kept = try XCTUnwrap(bubble.animation(forKey: "spaceLabelFlight") as? CAAnimationGroup)
            XCTAssertEqual(kept.beginTime, original.beginTime)
            XCTAssertEqual(kept.duration, original.duration)
            let points = try XCTUnwrap((kept.animations?.first as? CAKeyframeAnimation)?.values as? [NSValue])
            let oldPoints = try XCTUnwrap((original.animations?.first as? CAKeyframeAnimation)?.values as? [NSValue])
            XCTAssertEqual(points, oldPoints)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(overlay.dismissAt), now + 2)
        }
        let titles = bubble.sublayers?.compactMap { (($0 as? CATextLayer)?.string as? NSAttributedString)?.string }
        XCTAssertEqual(titles, ["Research", "Space 2"])
    }

    @MainActor
    func testLateSwitchPreservesVelocityWithoutNewTailAndGetsFreshIdleTime() throws {
        var now = CACurrentMediaTime()
        let overlay = SpaceLabelOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 700), clock: { now })
        defer { overlay.cancel() }
        overlay.show(name: "Work", ordinal: 1, visibleFrame: overlay.bounds, reduceMotion: false)
        let oldID = try XCTUnwrap(overlay.presentationID)
        let bubble = try XCTUnwrap(overlay.layer?.sublayers?.first)
        now = try XCTUnwrap(overlay.dismissAt)
        overlay.dismissIfDue(oldID)
        let original = try XCTUnwrap(bubble.animation(forKey: "spaceLabelFlight") as? CAAnimationGroup)
        let shape = try XCTUnwrap(bubble.sublayers?.first as? CAShapeLayer)
        let originalMorph = try XCTUnwrap(shape.animation(forKey: "spaceLabelDroplet") as? CAKeyframeAnimation)
        let index = 45
        let elapsed = original.duration * Double(index) / 60
        now += elapsed
        overlay.show(name: "Research", ordinal: 2, visibleFrame: overlay.bounds, reduceMotion: false)
        let settling = try XCTUnwrap(bubble.animation(forKey: "spaceLabelFlight") as? CAAnimationGroup)
        XCTAssertLessThanOrEqual(settling.duration, 0.5)
        try assertFlight(settling, startsAt: original, elapsed: elapsed)
        let oldPoints = try XCTUnwrap((original.animations?.first as? CAKeyframeAnimation)?.values as? [NSValue]).map(\.pointValue)
        let points = try XCTUnwrap((settling.animations?.first as? CAKeyframeAnimation)?.values as? [NSValue]).map(\.pointValue)
        let oldStep = original.duration / Double(oldPoints.count - 1)
        let keyTimes = try XCTUnwrap((settling.animations?.first as? CAKeyframeAnimation)?.keyTimes)
        let newStep = settling.duration * (keyTimes[1].doubleValue - keyTimes[0].doubleValue)
        let oldVelocity = (oldPoints[index + 1].y - oldPoints[index].y) / oldStep
        let initialVelocity = (points[1].y - points[0].y) / newStep
        XCTAssertLessThan(initialVelocity, 0, "Recovery must brake the downward movement instead of jumping upward")
        XCTAssertEqual(initialVelocity, oldVelocity, accuracy: abs(oldVelocity) * 0.05)
        let oldScales = try XCTUnwrap((original.animations?[1] as? CAKeyframeAnimation)?.values as? [NSNumber]).map(\.doubleValue)
        let scales = try XCTUnwrap((settling.animations?[1] as? CAKeyframeAnimation)?.values as? [NSNumber]).map(\.doubleValue)
        let oldScaleVelocity = (oldScales[index + 1] - oldScales[index]) / oldStep
        XCTAssertEqual((scales[1] - scales[0]) / newStep, oldScaleVelocity, accuracy: abs(oldScaleVelocity) * 0.05)
        let newMorph = try XCTUnwrap(shape.animation(forKey: "spaceLabelDroplet") as? CAKeyframeAnimation)
        let oldPath = try XCTUnwrap((originalMorph.values as? [CGPath])?[index])
        let paths = try XCTUnwrap(newMorph.values as? [CGPath])
        XCTAssertEqual(paths[0].boundingBoxOfPath.minX, oldPath.boundingBoxOfPath.minX, accuracy: 0.001)
        XCTAssertEqual(paths[0].boundingBoxOfPath.minY, oldPath.boundingBoxOfPath.minY, accuracy: 0.001)
        // Recovery relaxes the existing tail; it must not kick out a fresh one.
        for pair in zip(paths, paths.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.boundingBoxOfPath.minX + 0.001, pair.0.boundingBoxOfPath.minX)
            XCTAssertGreaterThanOrEqual(pair.1.boundingBoxOfPath.minY + 0.001, pair.0.boundingBoxOfPath.minY)
        }
        XCTAssertEqual(try XCTUnwrap(overlay.dismissAt), now + settling.duration + 2, accuracy: 0.001)
        overlay.finish(oldID)
        XCTAssertTrue(overlay.isPresenting)
        now += settling.duration / 2
        overlay.show(name: "Latest", ordinal: 3, visibleFrame: overlay.bounds, reduceMotion: false)
        let kept = try XCTUnwrap(bubble.animation(forKey: "spaceLabelFlight") as? CAAnimationGroup)
        XCTAssertEqual(kept.beginTime, settling.beginTime, "Rapid switches during recovery must leave the same ascent intact")
        XCTAssertEqual(kept.duration, settling.duration)
    }

    @MainActor
    func testReturnInterruptionStaysVisibleAndSettlesOnceAcrossTimingsAndDisplays() throws {
        for size in [CGSize(width: 800, height: 600), CGSize(width: 1512, height: 982), CGSize(width: 3840, height: 2160)] {
            for fraction in [0.05, 0.3, 0.6, 0.85, 0.95, 0.995] {
                var now = CACurrentMediaTime()
                let bounds = CGRect(origin: .zero, size: size)
                let overlay = SpaceLabelOverlay(frame: bounds, clock: { now })
                defer { overlay.cancel() }
                overlay.show(name: "Work", ordinal: 1, visibleFrame: bounds, reduceMotion: false)
                let oldID = try XCTUnwrap(overlay.presentationID)
                now = try XCTUnwrap(overlay.dismissAt)
                overlay.dismissIfDue(oldID)
                now += SpaceLabelOverlay.returnDuration * fraction
                overlay.show(name: "Research", ordinal: 2, visibleFrame: bounds, reduceMotion: false)
                let bubble = try XCTUnwrap(overlay.layer?.sublayers?.first)
                let recovery = try XCTUnwrap(bubble.animation(forKey: "spaceLabelFlight") as? CAAnimationGroup)
                let points = try XCTUnwrap((recovery.animations?.first as? CAKeyframeAnimation)?.values as? [NSValue]).map(\.pointValue)
                let scales = try XCTUnwrap((recovery.animations?[1] as? CAKeyframeAnimation)?.values as? [NSNumber]).map(\.doubleValue)
                let opacity = try XCTUnwrap((recovery.animations?[2] as? CAKeyframeAnimation)?.values as? [NSNumber]).map(\.doubleValue)
                XCTAssertTrue(points.allSatisfy { bounds.contains($0) }, "Recovery left display at \(size), \(fraction)")
                XCTAssertTrue(scales.allSatisfy { $0 > 0 && $0 <= 1 })
                XCTAssertTrue(opacity.allSatisfy { $0 > 0 && $0 <= 1 })
                XCTAssertTrue(zip(opacity, opacity.dropFirst()).allSatisfy { $1 >= $0 }, "Interrupted fade must not hide the label")
                let lowest = try XCTUnwrap(points.indices.min { points[$0].y < points[$1].y })
                XCTAssertTrue(zip(points[lowest...], points[(lowest + 1)...]).allSatisfy { $1.y >= $0.y }, "Only one direction change; no bouncing")
                XCTAssertEqual(points.last, SpaceLabelOverlay.destination(in: bounds, visibleFrame: bounds))
                overlay.finish(oldID)
                XCTAssertTrue(overlay.isPresenting)
            }
        }
    }

    @MainActor
    func testSwitchAfterCompletedReturnStartsFreshEntrance() throws {
        var now = CACurrentMediaTime()
        let overlay = SpaceLabelOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 700), clock: { now })
        defer { overlay.cancel() }
        overlay.show(name: "Work", ordinal: 1, visibleFrame: overlay.bounds, reduceMotion: false)
        let oldID = try XCTUnwrap(overlay.presentationID)
        now = try XCTUnwrap(overlay.dismissAt)
        overlay.dismissIfDue(oldID)
        now += SpaceLabelOverlay.returnDuration + 0.01
        overlay.finish(oldID)
        overlay.show(name: "Research", ordinal: 2, visibleFrame: overlay.bounds, reduceMotion: false)
        let bubble = try XCTUnwrap(overlay.layer?.sublayers?.first)
        let entrance = try XCTUnwrap(bubble.animation(forKey: "spaceLabelFlight") as? CAAnimationGroup)
        let points = try XCTUnwrap((entrance.animations?.first as? CAKeyframeAnimation)?.values as? [NSValue])
        XCTAssertEqual(points.first?.pointValue, SpaceLabelOverlay.widgetAnchor)
        XCTAssertEqual(entrance.duration, SpaceLabelOverlay.entranceDuration)
    }

    @MainActor
    func testRealTimerKeepsLatestLabelPastOldDeadlineThenReturnsOnce() async throws {
        let overlay = SpaceLabelOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        defer { overlay.cancel() }
        var visibilityChanges = 0
        overlay.onVisibilityChanged = { visibilityChanges += 1 }
        overlay.show(name: "Work", ordinal: 1, visibleFrame: overlay.bounds, reduceMotion: false)
        let originalDeadline = try XCTUnwrap(overlay.dismissAt)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        overlay.show(name: "Research", ordinal: 2, visibleFrame: overlay.bounds, reduceMotion: false)
        let latestDeadline = try XCTUnwrap(overlay.dismissAt)
        let bubble = try XCTUnwrap(overlay.layer?.sublayers?.first)
        let destination = bubble.position
        try await Task.sleep(nanoseconds: UInt64(max(0, originalDeadline + 0.1 - CACurrentMediaTime()) * 1_000_000_000))
        XCTAssertLessThan(CACurrentMediaTime(), latestDeadline)
        XCTAssertTrue(overlay.isPresenting, "The old deadline must not dismiss the latest Space")
        XCTAssertEqual(visibilityChanges, 1)
        XCTAssertNil(bubble.animationKeys(), "The held label must not start an early return")
        XCTAssertEqual(bubble.position, destination)
        XCTAssertEqual(bubble.opacity, 1)
        try await Task.sleep(nanoseconds: UInt64(max(0, latestDeadline + 0.5 - CACurrentMediaTime()) * 1_000_000_000))
        XCTAssertFalse(overlay.isPresenting)
        XCTAssertEqual(visibilityChanges, 2, "There is one appearance and one final disappearance")
    }

    @MainActor
    func testReducedMotionAlsoResetsDeadlineAndCancelsPendingDismissal() throws {
        var now = CACurrentMediaTime()
        let overlay = SpaceLabelOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 700), clock: { now })
        overlay.show(name: "Work", ordinal: 1, visibleFrame: overlay.bounds, reduceMotion: true)
        let oldID = try XCTUnwrap(overlay.presentationID)
        now += 1.5
        overlay.show(name: "Research", ordinal: 2, visibleFrame: overlay.bounds, reduceMotion: true)
        XCTAssertEqual(try XCTUnwrap(overlay.dismissAt), now + 2, accuracy: 0.001)
        overlay.dismissIfDue(oldID)
        XCTAssertTrue(overlay.isPresenting)
        let newID = try XCTUnwrap(overlay.presentationID)
        overlay.cancel()
        now += 4
        overlay.dismissIfDue(newID)
        XCTAssertFalse(overlay.isPresenting)
        XCTAssertNil(overlay.dismissAt)
        XCTAssertNil(overlay.layer?.sublayers?.first?.animationKeys())
    }

    private func assertFlight(_ replacement: CAAnimationGroup, startsAt original: CAAnimationGroup,
                              elapsed: TimeInterval, file: StaticString = #filePath, line: UInt = #line) throws {
        for key in ["position", "transform.scale", "opacity"] {
            let old = try XCTUnwrap(original.animations?.first { ($0 as? CAKeyframeAnimation)?.keyPath == key } as? CAKeyframeAnimation)
            let new = try XCTUnwrap(replacement.animations?.first { ($0 as? CAKeyframeAnimation)?.keyPath == key } as? CAKeyframeAnimation)
            let values = try XCTUnwrap(old.values)
            let offset = elapsed / original.duration * Double(values.count - 1)
            let lower = Int(offset), upper = min(lower + 1, values.count - 1)
            let fraction = offset - Double(lower)
            if key == "position" {
                let a = try XCTUnwrap(values[lower] as? NSValue).pointValue
                let b = try XCTUnwrap(values[upper] as? NSValue).pointValue
                let actual = try XCTUnwrap(new.values?.first as? NSValue).pointValue
                XCTAssertEqual(actual.x, a.x + (b.x - a.x) * fraction, accuracy: 0.1, file: file, line: line)
                XCTAssertEqual(actual.y, a.y + (b.y - a.y) * fraction, accuracy: 0.1, file: file, line: line)
            } else {
                let a = try XCTUnwrap(values[lower] as? NSNumber).doubleValue
                let b = try XCTUnwrap(values[upper] as? NSNumber).doubleValue
                let actual = try XCTUnwrap(new.values?.first as? NSNumber).doubleValue
                XCTAssertEqual(actual, a + (b - a) * fraction, accuracy: 0.001, file: file, line: line)
            }
        }
    }

    @MainActor
    func testNativeFlightStartsAndEndsAtWidgetAndStaysOnDisplay() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        var now = CACurrentMediaTime()
        let overlay = SpaceLabelOverlay(frame: bounds, clock: { now })
        overlay.show(name: "Development", ordinal: 2, visibleFrame: bounds, reduceMotion: false, revealDelay: 0.25)
        defer { overlay.cancel() }
        let bubble = try XCTUnwrap(overlay.layer?.sublayers?.first)
        let animation = try XCTUnwrap(bubble.animation(forKey: "spaceLabelFlight") as? CAAnimationGroup)
        let position = try XCTUnwrap(animation.animations?.first as? CAKeyframeAnimation)
        let points = try XCTUnwrap(position.values as? [NSValue]).map(\.pointValue)
        XCTAssertEqual(points.first, SpaceLabelOverlay.widgetAnchor)
        let destination = SpaceLabelOverlay.destination(in: bounds, visibleFrame: bounds)
        XCTAssertEqual(try XCTUnwrap(points.last).x, destination.x, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(points.last).y, destination.y, accuracy: 0.001)
        XCTAssertTrue(points.allSatisfy { bounds.contains($0) })
        XCTAssertTrue(points.contains { abs($0.x - bounds.midX) < 1 && $0.y > 500 })
        XCTAssertEqual(animation.duration, 0.55, accuracy: 0.001)
        now = try XCTUnwrap(overlay.dismissAt)
        overlay.dismissIfDue(try XCTUnwrap(overlay.presentationID))
        let returning = try XCTUnwrap(bubble.animation(forKey: "spaceLabelFlight") as? CAAnimationGroup)
        let returnPath = try XCTUnwrap(returning.animations?.first as? CAKeyframeAnimation)
        let returnPoints = try XCTUnwrap(returnPath.values as? [NSValue]).map(\.pointValue)
        XCTAssertEqual(returning.duration, 0.25, accuracy: 0.001)
        XCTAssertEqual(returnPoints.first, destination)
        XCTAssertEqual(returnPoints.last, SpaceLabelOverlay.widgetAnchor)
        XCTAssertTrue(returnPoints.allSatisfy { bounds.contains($0) })
        XCTAssertNil(overlay.hitTest(CGPoint(x: 500, y: 500)))
        XCTAssertFalse(overlay.acceptsFirstResponder)
    }

    @MainActor
    func testReducedMotionHasNoFlightOrMorphAnimations() throws {
        let overlay = SpaceLabelOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        overlay.show(name: "Untitled", ordinal: 3, visibleFrame: overlay.bounds, reduceMotion: true)
        defer { overlay.cancel() }
        let bubble = try XCTUnwrap(overlay.layer?.sublayers?.first)
        XCTAssertNil(bubble.animationKeys())
        XCTAssertEqual(bubble.opacity, 1)
        XCTAssertEqual(bubble.position.x, 500)
        XCTAssertTrue(bubble.sublayers?.allSatisfy { $0.animationKeys() == nil } == true)
        let titles = bubble.sublayers?.compactMap { ($0 as? CATextLayer)?.string as? NSAttributedString }
        XCTAssertEqual(titles?.map(\.string), ["Space 3"])
    }

    @MainActor
    func testExpandedLabelHasRoundSymmetricEndsWithoutResidualTail() throws {
        let overlay = SpaceLabelOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        overlay.show(name: "Work", ordinal: 1, visibleFrame: overlay.bounds, reduceMotion: false)
        defer { overlay.cancel() }
        let bubble = try XCTUnwrap(overlay.layer?.sublayers?.first)
        let shape = try XCTUnwrap(bubble.sublayers?.first as? CAShapeLayer)
        let animation = try XCTUnwrap(shape.animation(forKey: "spaceLabelDroplet") as? CAKeyframeAnimation)
        let paths = try XCTUnwrap(animation.values as? [CGPath])
        // The entrance ends at a static capsule; the return is separately scheduled.
        let held = try XCTUnwrap(paths.last)
        XCTAssertEqual(held.boundingBoxOfPath, CGRect(origin: .zero, size: SpaceLabelOverlay.bubbleSize))
        let radius = SpaceLabelOverlay.bubbleSize.height / 2
        let rightCenter = SpaceLabelOverlay.bubbleSize.width - radius
        for x in stride(from: CGFloat(0.5), to: SpaceLabelOverlay.bubbleSize.width, by: 1) {
            for y in stride(from: CGFloat(0.5), to: SpaceLabelOverlay.bubbleSize.height, by: 1) {
                let centerX = min(rightCenter, max(radius, x))
                let distance = hypot(x - centerX, y - radius)
                // Ignore subpixel cubic-circle approximation at the boundary.
                guard abs(distance - radius) > 0.1 else { continue }
                XCTAssertEqual(held.contains(CGPoint(x: x, y: y)), distance < radius,
                               "Expanded capsule contour differs at (\(x), \(y))")
            }
        }
    }

    @MainActor
    func testShapeTopologySupportsNativeInterpolationAndSafeArea() {
        func topology(_ path: CGPath) -> [Int32] {
            var result: [Int32] = []
            path.applyWithBlock { result.append($0.pointee.type.rawValue) }
            return result
        }
        let rest = SpaceLabelOverlay.dropletPath(tail: 0)
        let stretched = SpaceLabelOverlay.dropletPath(tail: 1.05)
        XCTAssertEqual(topology(rest), topology(stretched))
        XCTAssertLessThan(stretched.boundingBoxOfPath.minX, rest.boundingBoxOfPath.minX)
        let destination = SpaceLabelOverlay.destination(in: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 30, width: 800, height: 400))
        XCTAssertLessThanOrEqual(destination.y + SpaceLabelOverlay.bubbleSize.height / 2, 414)
    }

    @MainActor
    func testNativeAppearanceAndLabelRenderInLightAndDark() throws {
        _ = NSApplication.shared
        let suite = "SpaceLabelRender." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SpaceLabelSettings(defaults: defaults)
        settings.onPreview = { XCTFail("Rendering must not show a live overlay"); return false }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: AppearanceSettingsView(settings: settings)
                .environment(\.colorScheme, name == "light" ? .light : .dark)
                .background(name == "light" ? Color(nsColor: NSColor(calibratedWhite: 0.93, alpha: 1))
                            : Color(nsColor: NSColor(calibratedWhite: 0.16, alpha: 1))))
            view.frame = CGRect(x: 0, y: 0, width: 580, height: 500)
            view.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = view.appearance
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            try export(view, name: "appearance-\(name)")
            window.orderOut(nil)
        }
        let overlay = SpaceLabelOverlay(frame: CGRect(x: 0, y: 0, width: 800, height: 520))
        let window = NSWindow(contentRect: overlay.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = overlay
        overlay.show(name: "Development · 개발", ordinal: 2, visibleFrame: overlay.bounds, reduceMotion: true)
        overlay.layoutSubtreeIfNeeded()
        try export(overlay, name: "native-label")
        overlay.cancel()
        window.orderOut(nil)
    }

    @MainActor
    private func export(_ view: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        if let directory = ProcessInfo.processInfo.environment["SPACEWIDGET_LABEL_QA_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try png.write(to: url.appendingPathComponent(name + ".png"))
        }
    }
}
