import XCTest
@testable import SpaceWidget

final class AgentApplicationCaptureTests: XCTestCase {
    private let ghostty = AgentApplicationTarget(bundleID: "com.mitchellh.ghostty", processID: 42, name: "Ghostty")
    private let terminal = AgentApplicationTarget(bundleID: "com.apple.Terminal", processID: 43, name: "Terminal")
    func testCapturePrefersActualAncestorAndFallsBackToVerifiedTerminalEnvironment() {
        let apps = [ghostty, terminal]
        XCTAssertEqual(AgentApplicationCapture.resolve(ancestors: [99, 42],
            environment: ["TERM_PROGRAM": "Apple_Terminal"], applications: apps), ghostty)
        XCTAssertEqual(AgentApplicationCapture.resolve(ancestors: [],
            environment: ["TERM_PROGRAM": "ghostty"], applications: apps), ghostty)
        XCTAssertEqual(AgentApplicationCapture.resolve(ancestors: [],
            environment: ["__CFBundleIdentifier": terminal.bundleID], applications: apps), terminal)
        XCTAssertNil(AgentApplicationCapture.resolve(ancestors: [], environment: [:], applications: apps))
        XCTAssertNil(AgentApplicationCapture.resolve(ancestors: [],
            environment: ["TERM_PROGRAM": "ghostty"], applications: [terminal]))
        XCTAssertNil(AgentApplicationCapture.resolve(ancestors: [],
            environment: ["TERM_PROGRAM": "ghostty"], applications: [ghostty, ghostty]))
    }

    func testLiveTerminalApplicationCaptureWhenRequested() throws {
        guard let value = ProcessInfo.processInfo.environment["SPACEWIDGET_TEST_SOURCE_PID"],
              let pid = pid_t(value) else { throw XCTSkip("Opt-in read-only live terminal capture") }
        let app = try XCTUnwrap(AgentApplicationCapture.resolve(
            ancestors: AgentProcessAncestry.ancestors(from: pid), environment: [:],
            applications: AgentApplicationCapture.running()))
        XCTAssertEqual(app.bundleID, "com.mitchellh.ghostty")
        XCTAssertGreaterThan(app.processID, 1)
    }


    func testKnownAppWithoutKnownSpaceMustNotOfferAmbiguousAppActivation() {
        let event = AgentHookEvent(agentID: "claude", source: "fixture", session: "private", kind: "Stop",
            turn: nil, received: Date(), project: "my-project", application: ghostty)
        let unknown = AgentCompletionNotice(event: event, space: nil, isTest: false)
        XCTAssertNil(unknown.destination)
        XCTAssertEqual(unknown.detail, "Claude Code · Ghostty · Unknown Space")
        let origin = AgentOrigin(displayID: "d", spaceUUID: "request-space")
        let known = AgentCompletionNotice(event: event, space: "Space 2", isTest: false, origin: origin)
        XCTAssertEqual(known.destination, origin)
        XCTAssertEqual(known.actionTitle, "Go to Space 2")
        XCTAssertNil(AgentCompletionNotice(event: event, space: "Space 2", isTest: true, origin: origin).destination)
        XCTAssertNil(AgentCompletionNotice(event: event, space: "Space 2", isTest: false,
            origin: origin, navigationIssue: "Failed").destination)
    }
}
