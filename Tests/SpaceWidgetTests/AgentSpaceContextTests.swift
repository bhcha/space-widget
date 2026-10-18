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
        .init(agentID: "claude", source: "fixture", session: session, kind: kind, turn: turn, received: Date(), project: "my-project", origin: origin,
              originCapturePolicy: origin == nil ? nil : AgentSpaceCapture.policy)
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
        XCTAssertEqual(notice.originCapturePolicy, AgentSpaceCapture.policy)
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

    func testSessionStartCannotRedirectARequestButPromptWithoutTurnIDStillWorks() throws {
        let transport = HookEventTransport(installation: installation)
        try transport.enqueue(event("SessionStart", turn: nil, origin: a))
        try transport.enqueue(event("Stop", turn: "first"))
        let rejected = try XCTUnwrap(transport.drain().last)
        XCTAssertNil(rejected.origin, "A resumed session on SD must not redirect a text2sql request")
        XCTAssertEqual(rejected.contextMatch, "session_start_rejected")
        try transport.enqueue(event("UserPromptSubmit", turn: nil, origin: b))
        try transport.enqueue(event("Stop", turn: "second"))
        XCTAssertEqual(try transport.drain().last?.origin, b)
    }

    func testMidTurnCompactionOnAnotherSpacePreservesOriginalRequest() throws {
        let transport = HookEventTransport(installation: installation)
        let prompt = event("UserPromptSubmit", origin: a)
        try transport.enqueue(prompt)
        _ = try transport.drain()
        var compact = event("SessionStart", turn: nil, origin: b)
        compact.startSource = "compact"
        try transport.enqueue(compact)
        try transport.enqueue(event("Stop"))
        let completed = try XCTUnwrap(transport.drain().last)
        XCTAssertEqual(completed.origin, a)
        XCTAssertEqual(completed.contextMatch, "exact_turn")
        XCTAssertEqual(completed.contextTrace, prompt.traceID)
    }

    func testOldUnidentifiedPromptCannotOverrideANewerIdentifiedRequestOrResume() throws {
        let transport = HookEventTransport(installation: installation)
        try transport.enqueue(event("UserPromptSubmit", turn: nil, origin: b))
        try transport.enqueue(event("UserPromptSubmit", turn: "new", origin: a))
        try transport.enqueue(event("Stop", turn: "missing"))
        XCTAssertNil(try transport.drain().last?.origin)
        try transport.enqueue(event("SessionStart", turn: nil, origin: b))
        try transport.enqueue(event("Stop", turn: "after-resume"))
        XCTAssertNil(try transport.drain().last?.origin)
        // An exact still-running request is preserved across the lifecycle callback.
        try transport.enqueue(event("Stop", turn: "new"))
        XCTAssertEqual(try transport.drain().last?.origin, a)
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
        XCTAssertEqual(events.last?.originCapturePolicy, AgentSpaceCapture.policy)
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
        XCTAssertNil(event.originCapturePolicy)
    }

    func testLegacyContextCannotAcquireVerificationFromANewStop() throws {
        let transport = HookEventTransport(installation: installation)
        try transport.enqueue(event("UserPromptSubmit", origin: a))
        _ = try transport.drain()
        // Actual pre-v6 JSON omitted this field in both events and contexts.
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: transport.file)) as? [String: Any])
        var contexts = try XCTUnwrap(state["contexts"] as? [[String: Any]])
        for index in contexts.indices { contexts[index].removeValue(forKey: "originCapturePolicy") }
        state["contexts"] = contexts
        try JSONSerialization.data(withJSONObject: state).write(to: transport.file)
        var stop = event("Stop", origin: b)
        stop.originCapturePolicy = AgentSpaceCapture.policy
        try HookEventTransport(installation: installation).enqueue(stop)
        let completed = try XCTUnwrap(transport.drain().last)
        XCTAssertEqual(completed.origin, a, "Historical metadata remains available for diagnostics")
        XCTAssertNil(completed.originCapturePolicy, "Stop cannot certify an older prompt capture")

        let payload: [String: Any] = ["session_id": "s", "hook_event_name": "UserPromptSubmit",
            "originCapturePolicy": AgentSpaceCapture.policy, "origin": ["displayID": "display", "spaceUUID": "b"]]
        let parsed = try XCTUnwrap(AgentHookEvent.parse(payload, installation: installation, expectedKind: "UserPromptSubmit"))
        XCTAssertNil(parsed.origin)
        XCTAssertNil(parsed.originCapturePolicy, "Provider input is not capture evidence")
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
