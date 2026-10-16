import XCTest
@testable import SpaceWidget

final class AgentSpaceContextTests: XCTestCase {
    private var root: URL!
    private var installation: HookInstallation!
    private let a = AgentOrigin(displayID: "display", spaceUUID: "a")
    private let b = AgentOrigin(displayID: "display", spaceUUID: "b")
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        installation = HookInstallation(agent: .claude, directory: root)
        try installation.install(helperBytes: Data("fixture".utf8))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func event(_ kind: String, turn: String? = "t", origin: AgentOrigin? = nil, session: String = "s") -> AgentHookEvent {
        .init(agentID: "claude", source: "fixture", session: session, kind: kind, turn: turn, received: Date(), project: "my-project", origin: origin)
    }

    func testRequestSpaceSurvivesDrainRestartAndCompletionOnAnotherDesktop() throws {
        let transport = HookEventTransport(installation: installation)
        try transport.enqueue(event("SessionStart", turn: nil, origin: a))
        try transport.enqueue(event("UserPromptSubmit", origin: b))
        _ = try transport.drain()
        let restarted = HookEventTransport(installation: installation)
        // Completion's foreground must never overwrite the request's Space.
        try restarted.enqueue(event("Stop", origin: a))
        let notice = try XCTUnwrap(restarted.drain().first)
        XCTAssertEqual(notice.origin, b)
        XCTAssertEqual(notice.project, "my-project")
        try restarted.enqueue(event("Stop", turn: "other-session", session: "other"))
        XCTAssertNil(try restarted.drain().first?.origin)
    }

    func testIndependentOverlappingTurnsAndUnknownRequestDoNotReuseWrongSpace() throws {
        let transport = HookEventTransport(installation: installation)
        try transport.enqueue(event("SessionStart", turn: nil, origin: a))
        try transport.enqueue(event("UserPromptSubmit", turn: "1", origin: a))
        try transport.enqueue(event("UserPromptSubmit", turn: "2", origin: b))
        _ = try transport.drain()
        try transport.enqueue(event("Stop", turn: "1"))
        try transport.enqueue(event("Stop", turn: "2"))
        XCTAssertEqual(try transport.drain().map(\.origin), [a, b])
        try transport.enqueue(event("UserPromptSubmit", turn: "3", origin: nil))
        try transport.enqueue(event("Stop", turn: "3"))
        XCTAssertNil(try transport.drain().last?.origin)
        try transport.enqueue(event("Stop", turn: "unknown-turn"))
        XCTAssertNil(try transport.drain().first?.origin)
    }

    func testSessionStartFallbackAndPromptWithoutTurnID() throws {
        let transport = HookEventTransport(installation: installation)
        try transport.enqueue(event("SessionStart", turn: nil, origin: a))
        try transport.enqueue(event("Stop", turn: "first"))
        XCTAssertEqual(try transport.drain().last?.origin, a)
        try transport.enqueue(event("UserPromptSubmit", turn: nil, origin: b))
        try transport.enqueue(event("Stop", turn: "second"))
        XCTAssertEqual(try transport.drain().last?.origin, b)
    }

    func testReceiverOnlyCapturesAtStartAndPromptAndQueuesCompletedProjectWithSpace() throws {
        let input = root.appendingPathComponent("input")
        let app = AgentApplicationTarget(bundleID: "com.mitchellh.ghostty", processID: 42, name: "Ghostty")
        var captureCount = 0
        func run(_ kind: String, origin: AgentOrigin) throws {
            let payload: [String: Any] = ["session_id": "session", "hook_event_name": kind, "prompt_id": "turn", "cwd": root.appendingPathComponent("space-widget").path, "prompt": "PRIVATE"]
            try JSONSerialization.data(withJSONObject: payload).write(to: input)
            let handle = try FileHandle(forReadingFrom: input)
            defer { try? handle.close() }
            HookInstallationReceiver.run(arguments: [installation.helper.path, "--spacewidget-hook", "claude", root.path, kind], input: handle.fileDescriptor) {
                captureCount += 1
                return .init(origin: origin, application: app)
            }
        }
        try run("UserPromptSubmit", origin: a)
        try run("Stop", origin: b)
        XCTAssertEqual(captureCount, 1)
        let events = try HookEventTransport(installation: installation).drain()
        XCTAssertEqual(events.last?.origin, a)
        XCTAssertEqual(events.last?.project, "space-widget")
        XCTAssertEqual(events.last?.application, app)
        XCTAssertFalse(try String(contentsOf: HookEventTransport(installation: installation).file).contains("PRIVATE"))
    }

    func testV1EventSpoolStillDecodesWithoutInventingSpace() throws {
        let data = try JSONSerialization.data(withJSONObject: ["events": [["agentID": "claude", "source": "v1", "session": "old", "kind": "Stop", "received": 0]], "seen": []])
        let transport = HookEventTransport(installation: installation)
        try data.write(to: transport.file)
        let event = try XCTUnwrap(transport.drain().first)
        XCTAssertNil(event.origin)
        XCTAssertNil(event.project)
        XCTAssertNil(event.application)
    }

    func testCapturedApplicationSurvivesDrainAndNeverUsesCompletionHostOrStalePrompt() throws {
        let transport = HookEventTransport(installation: installation)
        let app = AgentApplicationTarget(bundleID: "com.mitchellh.ghostty", processID: 42, name: "Ghostty")
        let other = AgentApplicationTarget(bundleID: "com.apple.Terminal", processID: 43, name: "Terminal")
        var prompt = event("UserPromptSubmit")
        prompt.application = app
        try transport.enqueue(prompt)
        _ = try transport.drain()
        var stop = event("Stop")
        stop.application = other
        try transport.enqueue(stop)
        XCTAssertEqual(try transport.drain().first?.application, app)
        try transport.enqueue(event("UserPromptSubmit", turn: "new"))
        try transport.enqueue(event("Stop", turn: "new"))
        XCTAssertNil(try transport.drain().last?.application)
    }
}
