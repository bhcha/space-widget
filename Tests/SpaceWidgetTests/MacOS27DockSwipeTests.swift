import XCTest
import CoreGraphics
@testable import SpaceWidget

final class MacOS27DockSwipeTests: XCTestCase {
    func testNativeEventRoundTripRetainsAllPhasesAndHIDPayload() throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
            throw XCTSkip("macOS 27 native gesture serialization")
        }
        for right in [false, true] {
            let events = try XCTUnwrap(MacOS27DockSwipe.makeEvents(goRight: right, steps: 1, naturalScrollingEnabled: true))
            XCTAssertEqual(events.count, 3)
            for (event, phase) in zip(events, [Int64(1), 2, 4]) {
                let data = try XCTUnwrap(event.data) as Data
                let restored = try XCTUnwrap(CGEvent(withDataAllocator: kCFAllocatorDefault, data: data as CFData))
                XCTAssertEqual(restored.getIntegerValueField(CGEventField(rawValue: 55)!), 30)
                XCTAssertEqual(restored.getIntegerValueField(CGEventField(rawValue: 132)!), phase)
                XCTAssertEqual(restored.getIntegerValueField(CGEventField(rawValue: 134)!), phase)
                XCTAssertEqual(restored.getDoubleValueField(CGEventField(rawValue: 129)!), right ? 2000 : -2000)
                // Native reserialization must retain the 96-byte IOHID field 4205.
                let marker = try XCTUnwrap(data.range(of: Data([0, 96, 0x10, 0x6D])))
                XCTAssertGreaterThanOrEqual(data.distance(from: marker.upperBound, to: data.endIndex), 96)
            }
        }
    }

    func testNaturalScrollingOffReversesHIDDirectionForTheSameDestination() throws {
        let natural = try XCTUnwrap(MacOS27DockSwipe.makeEvents(goRight: true, steps: 2, naturalScrollingEnabled: true))
        let inverted = try XCTUnwrap(MacOS27DockSwipe.makeEvents(goRight: true, steps: 2, naturalScrollingEnabled: false))
        XCTAssertEqual(natural[0].getDoubleValueField(CGEventField(rawValue: 129)!), 4000)
        XCTAssertEqual(inverted[0].getDoubleValueField(CGEventField(rawValue: 129)!), -4000)
        XCTAssertNil(MacOS27DockSwipe.makeEvents(goRight: true, steps: 0, naturalScrollingEnabled: true))
    }
}
