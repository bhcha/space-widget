import XCTest
import Darwin
@testable import SpaceWidget

final class AgentProcessAncestryTests: XCTestCase {
    func testProtectedLoginDoesNotHideTheOwningTerminal() {
        // helper → shell → agent → login (BSD lookup denied) → terminal → launchd
        let parents: [pid_t: pid_t] = [60: 50, 50: 40, 40: 30, 20: 1]
        var fallbackReads: [pid_t] = []
        let chain = AgentProcessAncestry.ancestors(from: 60) { pid in
            AgentProcessAncestry.parent(of: pid, bsd: { parents[$0] }, kernel: {
                fallbackReads.append($0)
                return $0 == 30 ? 20 : nil
            })
        }
        XCTAssertEqual(chain, [60, 50, 40, 30, 20])
        XCTAssertEqual(fallbackReads, [30])
    }

    func testExitedProcessesAndCyclesStopWithoutInventingAnOwner() {
        XCTAssertNil(AgentProcessAncestry.parent(of: 10, bsd: { _ in nil }, kernel: { _ in nil }))
        XCTAssertEqual(AgentProcessAncestry.ancestors(from: 10, parent: { _ in nil }), [10])
        XCTAssertEqual(AgentProcessAncestry.ancestors(from: 10, parent: { $0 == 10 ? 20 : 10 }), [10, 20])
        XCTAssertEqual(AgentProcessAncestry.ancestors(from: 100, parent: { $0 + 1 }).count, 32)
        XCTAssertTrue(AgentProcessAncestry.ancestors(from: 1).isEmpty)
    }

    func testNativeKernelLookupReadsParentAndRejectsMissingProcess() {
        XCTAssertEqual(AgentProcessAncestry.kernelParent(of: getpid()), getppid())
        XCTAssertNil(AgentProcessAncestry.kernelParent(of: Int32.max))
    }

    func testLiveTerminalSourceCaptureWhenRequested() throws {
        let env = ProcessInfo.processInfo.environment
        guard let value = env["SPACEWIDGET_TEST_SOURCE_PID"], let pid = pid_t(value),
              let expectedUUID = env["SPACEWIDGET_TEST_SPACE_UUID"] else {
            throw XCTSkip("Opt-in read-only validation against a live terminal process")
        }
        let ancestors = AgentProcessAncestry.ancestors(from: pid)
        let origin = try XCTUnwrap(AgentSpaceCapture.capture(ancestors: ancestors))
        XCTAssertEqual(origin.spaceUUID, expectedUUID)
        XCTAssertNotNil(AgentSpaceCapture.spaces().first { $0.origin == origin })
    }
}
