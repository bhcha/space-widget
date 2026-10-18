import XCTest
import Darwin
import AppKit
@testable import SpaceWidget

final class AgentHookEventTests: XCTestCase {
    private var root: URL!
    private var installation: HookInstallation!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        installation = HookInstallation(agent: .claude, directory: root)
        try installation.install(helperBytes: Data("fixture".utf8))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func event(turn: String? = "turn", kind: String = "Stop", at: Date = Date()) -> AgentHookEvent {
        var payload: [String: Any] = ["session_id": "session", "hook_event_name": kind]
        payload["turn_id"] = turn
        return AgentHookEvent.parse(payload, installation: installation, expectedKind: kind, now: at)!
    }

    private func withoutPrompt(_ event: AgentHookEvent) -> AgentHookEvent {
        var event = event
        event.contextMatch = "no_prompt_match"
        return event
    }

    func testAllowlistRejectsRecursiveSubagentsMalformedAndDoesNotPersistContent() throws {
        var object: [String: Any] = ["session_id": "session", "hook_event_name": "Stop", "turn_id": "t",
            "prompt": "SECRET", "last_assistant_message": "SECRET", "transcript_path": "/never/read", "cwd": "/private/project"]
        let parsed = try XCTUnwrap(AgentHookEvent.parse(object, installation: installation, expectedKind: "Stop"))
        let transport = HookEventTransport(installation: installation)
        try transport.enqueue(parsed)
        let permissions = try FileManager.default.attributesOfItem(atPath: transport.file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let saved = try String(contentsOf: transport.file)
        for forbidden in ["SECRET", "transcript", "\"prompt\":", "/private/project", "cwd"] { XCTAssertFalse(saved.contains(forbidden)) }
        for (key, value) in [("stop_hook_active", true as Any), ("agent_id", "child"), ("subagent_id", "child")] {
            object[key] = value
            XCTAssertNil(AgentHookEvent.parse(object, installation: installation, expectedKind: "Stop"))
            object.removeValue(forKey: key)
        }
        object["session_id"] = "bad\ncontrol"
        XCTAssertNil(AgentHookEvent.parse(object, installation: installation, expectedKind: "Stop"))
        object["session_id"] = String(repeating: "s", count: 513)
        XCTAssertNil(AgentHookEvent.parse(object, installation: installation, expectedKind: "Stop"))
        XCTAssertNil(AgentHookEvent.parse(["session_id": "s", "hook_event_name": "SubagentStop"], installation: installation, expectedKind: "SubagentStop"))
    }

    func testBoundedQueueRestartDedupAndIndependentSources() throws {
        let transport = HookEventTransport(installation: installation)
        let first = event()
        XCTAssertTrue(try transport.enqueue(first))
        XCTAssertFalse(try transport.enqueue(first))
        XCTAssertEqual(try transport.drain(), [withoutPrompt(first)])
        let restarted = HookEventTransport(installation: installation)
        XCTAssertFalse(try restarted.enqueue(first))
        XCTAssertTrue(try restarted.drain().isEmpty)
        for index in 0..<600 { try transport.enqueue(event(turn: "t\(index)")) }
        XCTAssertLessThanOrEqual(try Data(contentsOf: transport.file).count, HookEventTransport.maximumBytes)
        XCTAssertEqual(try transport.drain().count, HookEventTransport.maximumEvents)
        let other = HookInstallation(agent: .claude, directory: root.appendingPathComponent("other"))
        let otherEvent = try XCTUnwrap(AgentHookEvent.parse(["session_id": "session", "hook_event_name": "Stop"], installation: other, expectedKind: "Stop"))
        XCTAssertNotEqual(first.sessionKey, otherEvent.sessionKey)
        let codex = HookInstallation(agent: .codex, directory: root)
        XCTAssertNotEqual(first.sessionKey, AgentHookEvent.parse(["session_id": "session", "hook_event_name": "Stop"], installation: codex, expectedKind: "Stop")?.sessionKey)
    }

    func testNoTurnRetryWindowDoesNotSuppressLaterResponsesAndStartIsSeparate() throws {
        let transport = HookEventTransport(installation: installation)
        let time = Date()
        XCTAssertTrue(try transport.enqueue(event(turn: nil, at: time)))
        XCTAssertFalse(try transport.enqueue(event(turn: nil, at: time.addingTimeInterval(1))))
        XCTAssertTrue(try transport.enqueue(event(turn: nil, at: time.addingTimeInterval(3))))
        XCTAssertTrue(try transport.enqueue(event(turn: nil, kind: "SessionStart", at: time)))
        XCTAssertEqual(try transport.drain().count, 3)
    }

    func testClaudePromptIdentitySeparatesFastResponsesAndDeduplicatesLaterRetries() throws {
        let time = Date()
        func parsed(_ prompt: String, seconds: TimeInterval = 0) throws -> AgentHookEvent {
            try XCTUnwrap(AgentHookEvent.parse([
                "hook_event_name": "Stop", "session_id": "claude-session", "prompt_id": prompt
            ], installation: installation, expectedKind: "Stop", now: time.addingTimeInterval(seconds)))
        }
        let transport = HookEventTransport(installation: installation)
        let first = try parsed("prompt-1")
        let second = try parsed("prompt-2", seconds: 0.2)
        XCTAssertTrue(try transport.enqueue(first))
        XCTAssertTrue(try transport.enqueue(second), "Different prompts must not be throttled as retries")
        XCTAssertEqual(try transport.drain(), [withoutPrompt(first), withoutPrompt(second)])
        let restarted = HookEventTransport(installation: installation)
        XCTAssertFalse(try restarted.enqueue(parsed("prompt-1", seconds: 30)))
        XCTAssertTrue(try restarted.drain().isEmpty)
        XCTAssertNil(AgentHookEvent.parse([
            "hook_event_name": "Stop", "session_id": "claude-session", "prompt_id": "bad\nvalue"
        ], installation: installation, expectedKind: "Stop"))
    }

    func testNamedPrimaryClaudeAgentNotMistakenForSubagent() throws {
        var payload: [String: Any] = ["session_id": "primary", "hook_event_name": "Stop",
                                      "agent_type": "reviewer", "prompt_id": "prompt"]
        XCTAssertNotNil(AgentHookEvent.parse(payload, installation: installation, expectedKind: "Stop"))
        payload["agent_id"] = "child"
        XCTAssertNil(AgentHookEvent.parse(payload, installation: installation, expectedKind: "Stop"))
    }

    func testPriorProcessEventsWaitForExplicitDrainWhileCurrentEventsFlow() throws {
        let transport = HookEventTransport(installation: installation)
        let start = Date()
        let old = event(turn: "old", at: start.addingTimeInterval(-10))
        let current = event(turn: "new", at: start.addingTimeInterval(1))
        try transport.enqueue(old); try transport.enqueue(current)
        XCTAssertEqual(try transport.pendingCount(before: start), 1)
        XCTAssertEqual(try transport.drain(since: start), [withoutPrompt(current)])
        XCTAssertEqual(try transport.pendingCount(before: start), 1)
        XCTAssertEqual(try transport.drain(), [withoutPrompt(old)])
        XCTAssertFalse(try transport.enqueue(old), "Explicit discard/view must not permit retry replay")
    }

    func testLockContentionCorruptionOversizeAndSymlinkFailPromptly() throws {
        let transport = HookEventTransport(installation: installation)
        let lock = installation.support.appendingPathComponent("events-v1.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let start = Date()
        XCTAssertThrowsError(try transport.enqueue(event()))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        flock(fd, LOCK_UN)
        try Data("invalid".utf8).write(to: transport.file)
        XCTAssertThrowsError(try transport.drain())
        XCTAssertEqual(try String(contentsOf: transport.file), "invalid")
        try Data(repeating: 0, count: HookEventTransport.maximumBytes + 1).write(to: transport.file)
        XCTAssertThrowsError(try transport.drain())
        try FileManager.default.removeItem(at: transport.file)
        let external = root.appendingPathComponent("untouched")
        try Data("keep".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: transport.file, withDestinationURL: external)
        XCTAssertThrowsError(try transport.enqueue(event()))
        XCTAssertEqual(try String(contentsOf: external), "keep")
    }

    func testReceiverEnqueuesMetadataAndReturnsOnDeliveryFailure() throws {
        let input = root.appendingPathComponent("input")
        try Data("{\"session_id\":\"s\",\"hook_event_name\":\"Stop\",\"prompt\":\"SECRET\"}".utf8).write(to: input)
        func run() throws {
            let handle = try FileHandle(forReadingFrom: input)
            defer { try? handle.close() }
            HookInstallationReceiver.run(arguments: [installation.helper.path, "--spacewidget-hook", "claude", root.path, "Stop"], input: handle.fileDescriptor)
        }
        try run()
        let transport = HookEventTransport(installation: installation)
        XCTAssertEqual(try transport.drain().first?.session, "s")
        try Data("corrupt".utf8).write(to: transport.file)
        XCTAssertNoThrow(try run())
        XCTAssertEqual(try String(contentsOf: transport.file), "corrupt")
    }

    func testReceiverDeadlineOnOpenPipe() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let start = Date()
        HookInstallationReceiver.run(arguments: [installation.helper.path, "--spacewidget-hook", "claude", root.path, "Stop"], input: pipe.fileHandleForReading.fileDescriptor)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: HookEventTransport(installation: installation).file.path))
    }

    @MainActor
    func testNativeToastRendersWithoutActivatingOrClaimingNavigation() throws {
        _ = NSApplication.shared
        let presenter = AgentToastPresenter()
        let notice = AgentCompletionNotice(event: event(), space: nil, isTest: true)
        presenter.show(notice)
        let panel = try XCTUnwrap(presenter.panel)
        defer { panel.orderOut(nil) }
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.isKeyWindow)
        let view = try XCTUnwrap(panel.contentView)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.bounds.size, AgentToastPresenter.toastSize)
        XCTAssertEqual(AgentToastPresenter.toastSize, SpaceLabelOverlay.bubbleSize)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        // Optional external QA capture is explicit and always outside agent configuration.
        if let destination = ProcessInfo.processInfo.environment["SPACEWIDGET_TOAST_TEST_PNG"] {
            try png.write(to: URL(fileURLWithPath: destination))
        }
    }

    @MainActor
    func testTransportToNotificationPollingRestartAndPendingActions() async throws {
        let suite = "SpaceWidgetFixture." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = Date()
        var notices: [AgentCompletionNotice] = []
        let transport = HookEventTransport(installation: installation)
        let old = event(turn: "old", at: started.addingTimeInterval(-10))
        let fresh = event(turn: "fresh", at: started.addingTimeInterval(1))
        try transport.enqueue(old); try transport.enqueue(fresh)
        let model = AgentNotificationModel(defaults: defaults, startedAt: started, installations: [installation],
            present: { notices.append($0) }, playSound: {})
        await model.poll()
        XCTAssertEqual(notices.map(\.event), [withoutPrompt(fresh)]); XCTAssertEqual(model.pendingCount, 1)
        await model.poll()
        XCTAssertEqual(notices.count, 1)
        await model.resolvePending(show: true)
        XCTAssertEqual(notices.map(\.event), [withoutPrompt(fresh), withoutPrompt(old)])
        XCTAssertEqual(model.pendingCount, 0)
        let restarted = AgentNotificationModel(defaults: defaults, startedAt: started, installations: [installation],
            present: { notices.append($0) }, playSound: {})
        XCTAssertFalse(try transport.enqueue(fresh))
        await restarted.poll(); XCTAssertEqual(notices.count, 2)
        try transport.enqueue(event(turn: "discard", at: started.addingTimeInterval(-1)))
        await restarted.poll(); XCTAssertEqual(restarted.pendingCount, 1)
        await restarted.resolvePending(show: false)
        XCTAssertEqual(notices.count, 2)
        XCTAssertTrue(try transport.drain().isEmpty)
        try Data("broken".utf8).write(to: transport.file)
        await restarted.poll()
        XCTAssertNotNil(restarted.deliveryIssue)
        XCTAssertEqual(notices.count, 2)
    }

    @MainActor
    func testNotificationControlsPreviewSessionStartAndTruthfulSpace() throws {
        let suite = "SpaceWidgetFixture." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var notices: [AgentCompletionNotice] = []
        var sounds = 0
        var starts = 0
        let model = AgentNotificationModel(defaults: defaults, present: { notices.append($0) }, playSound: { sounds += 1 })
        model.onSessionStart = { _ in starts += 1 }
        model.receive(event(kind: "SessionStart"))
        XCTAssertEqual(starts, 1); XCTAssertTrue(notices.isEmpty)
        model.receive(event())
        XCTAssertEqual(notices.last?.title, "Unknown project")
        XCTAssertEqual(notices.last?.detail, "Claude Code · Unknown Space")
        XCTAssertEqual(notices.last?.status, "done")
        XCTAssertEqual(sounds, 0)
        model.soundEnabled = true
        model.receive(event(turn: "next"))
        XCTAssertNil(notices.last?.space)
        XCTAssertEqual(sounds, 1)
        XCTAssertTrue(model.testNotification(agent: .codex))
        XCTAssertTrue(notices.last!.isTest)
        XCTAssertEqual(notices.last?.event.agent, .codex)
        XCTAssertNil(notices.last?.space, "Preview cannot pretend to have an origin")
        model.notificationsEnabled = false
        let count = notices.count
        model.receive(event()); XCTAssertFalse(model.testNotification())
        XCTAssertEqual(notices.count, count); XCTAssertEqual(sounds, 2)
        let restarted = AgentNotificationModel(defaults: defaults, present: { _ in XCTFail("Unexpected notification") }, playSound: {})
        XCTAssertFalse(restarted.notificationsEnabled); XCTAssertTrue(restarted.soundEnabled)
    }
}
