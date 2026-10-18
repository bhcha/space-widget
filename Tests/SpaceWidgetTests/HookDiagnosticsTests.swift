import XCTest
import AppKit
@testable import SpaceWidget

final class HookDiagnosticsTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func records(_ url: URL) throws -> [HookDiagnostics.Record] {
        try Data(contentsOf: url).split(separator: 0x0a).map { try JSONDecoder().decode(HookDiagnostics.Record.self, from: Data($0)) }
    }

    func testAppendSurvivesNewWriterAndRotationIsBoundedAndPrivate() throws {
        let url = root.appendingPathComponent("diagnostics.jsonl")
        let sink = HookDiagnostics.file(at: url, maximumBytes: 1024)
        sink.emit("first")
        HookDiagnostics.file(at: url, maximumBytes: 1024).emit("second")
        XCTAssertEqual(try records(url).map(\.stage), ["first", "second"])
        for i in 0..<30 { sink.emit("sample", fields: ["sequence": String(i), "value": String(repeating: "x", count: 90)]) }
        for file in [url, URL(fileURLWithPath: url.path + ".1")] {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 1024)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertFalse(try records(file).isEmpty)
        }
        XCTAssertEqual(try records(url).last?.fields["sequence"], "29")
    }

    func testConcurrentWritersProduceWholeJSONRecordsAndRejectSymlinks() throws {
        let url = root.appendingPathComponent("diagnostics.jsonl")
        DispatchQueue.concurrentPerform(iterations: 12) { i in
            HookDiagnostics.file(at: url).emit("parallel", fields: ["writer": String(i)])
        }
        let rows = try records(url)
        XCTAssertEqual(Set(rows.compactMap { $0.fields["writer"] }).count, 12)
        let outside = root.appendingPathComponent("untouched")
        try Data("original".utf8).write(to: outside)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        HookDiagnostics.file(at: link).emit("must_not_write")
        XCTAssertEqual(try String(contentsOf: outside), "original")
    }

    func testReceiverLogsCaptureMatchingAndCommitWithoutPayloadOrRawSession() throws {
        let installation = HookInstallation(agent: .claude, directory: root)
        try installation.install(helperBytes: Data("fixture".utf8))
        let url = root.appendingPathComponent("trace.jsonl")
        let diagnostics = HookDiagnostics.file(at: url)
        let origin = AgentOrigin(displayID: "display", spaceUUID: "text2sql-space")
        for kind in ["UserPromptSubmit", "Stop"] {
            let payload: [String: Any] = ["session_id": "RAW_SECRET_SESSION", "prompt_id": "RAW_SECRET_TURN",
                "hook_event_name": kind, "cwd": "/PRIVATE_PARENT/text2sql", "prompt": "PRIVATE_PROMPT",
                "last_assistant_message": "PRIVATE_RESPONSE", "transcript_path": "/PRIVATE_TRANSCRIPT"]
            let input = root.appendingPathComponent("input")
            try JSONSerialization.data(withJSONObject: payload).write(to: input)
            let handle = try FileHandle(forReadingFrom: input)
            defer { try? handle.close() }
            HookInstallationReceiver.run(arguments: [installation.helper.path, "--spacewidget-hook", "claude", root.path, kind],
                input: handle.fileDescriptor, diagnostics: diagnostics) {
                .init(origin: origin, application: nil, diagnostics: ["capture_reason": "single_host_space"])
            }
        }
        let rows = try records(url)
        let prompt = try XCTUnwrap(rows.first { $0.stage == "capture.completed" })
        let stop = try XCTUnwrap(rows.first { $0.stage == "context.resolved" })
        XCTAssertEqual(stop.fields["context_trace"], prompt.fields["trace"])
        XCTAssertEqual(stop.fields["request"], prompt.fields["request"])
        XCTAssertEqual(stop.fields["context_match"], "exact_turn")
        XCTAssertEqual(stop.fields["origin_uuid"], origin.spaceUUID)
        XCTAssertEqual(rows.filter { $0.stage == "transport.committed" }.count, 2)
        let text = try String(contentsOf: url)
        for secret in ["RAW_SECRET", "PRIVATE_PARENT", "PRIVATE_PROMPT", "PRIVATE_RESPONSE", "PRIVATE_TRANSCRIPT"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
    }

    @MainActor
    func testWrongArrivalRecordsBothRequestedAndActualUUID() async throws {
        let url = root.appendingPathComponent("wrong-arrival.jsonl")
        let backend = OriginBackendFixture()
        let sql = AgentOriginSnapshot.Space(uuid: "text2sql", id: 4, ordinal: 2, displayID: "display")
        let sd = AgentOriginSnapshot.Space(uuid: "sd", id: 5, ordinal: 3, displayID: "display")
        backend.state = .init(permitted: true, spaces: [sql, sd])
        backend.afterSwitch = { backend.current = sd.id }
        let navigation = AgentOriginNavigation(backend: backend, log: { _ in },
            diagnostics: .file(at: url), wait: { _ in })
        let reached = await navigation.navigate(to: sql.origin)
        XCTAssertFalse(reached)
        let finished = try XCTUnwrap(records(url).last)
        XCTAssertEqual(finished.stage, "navigation.finished")
        XCTAssertEqual(finished.fields["outcome"], "not_reached")
        XCTAssertEqual(finished.fields["destination_uuid"], sql.uuid)
        XCTAssertEqual(finished.fields["actual_uuid"], sd.uuid)
    }

    @MainActor
    func testOptInNativeRoundTripRecordsActualArrival() async throws {
        guard let uuid = ProcessInfo.processInfo.environment["SPACEWIDGET_QA_TARGET_UUID"],
              let path = ProcessInfo.processInfo.environment["SPACEWIDGET_QA_TRACE_PATH"] else {
            throw XCTSkip("Explicit target UUID and evidence path are required for real desktop switching")
        }
        _ = NSApplication.shared
        let backend = NativeAgentOriginBackend()
        let snapshot = backend.snapshot()
        XCTAssertTrue(snapshot.permitted, "Accessibility is required; this test never prompts")
        guard snapshot.permitted else { return }
        let target = try XCTUnwrap(snapshot.spaces.first { $0.uuid == uuid })
        let currentID = try XCTUnwrap(backend.currentSpace(on: target.displayID))
        let original = try XCTUnwrap(snapshot.spaces.first { $0.id == currentID && $0.displayID == target.displayID })
        XCTAssertNotEqual(original.uuid, target.uuid, "Choose a different target to exercise a real switch")
        guard original.uuid != target.uuid else { return }
        let diagnostics = HookDiagnostics.file(at: URL(fileURLWithPath: path))
        let navigation = AgentOriginNavigation(backend: backend, log: { _ in }, diagnostics: diagnostics)
        let event = AgentHookEvent(agentID: "codex", source: "native-qa", session: UUID().uuidString,
            kind: "Stop", turn: "round-trip", received: Date(), project: "SpaceWidget native navigation QA", origin: target.origin)
        for _ in 0..<2 {
            let reached = await navigation.navigate(to: target.origin, event: event)
            let restored = await navigation.navigate(to: original.origin, event: event)
            XCTAssertTrue(reached)
            XCTAssertTrue(restored, "The test must return to the starting desktop")
            if !restored { break }
        }
    }

    @MainActor
    func testOverlappingProjectsTraceToTheirOwnToastAndActualSpace() async throws {
        _ = NSApplication.shared
        let installation = HookInstallation(agent: .codex, directory: root)
        try installation.install(helperBytes: Data("fixture".utf8))
        let url = root.appendingPathComponent("trace.jsonl")
        let diagnostics = HookDiagnostics.file(at: url)
        let transport = HookEventTransport(installation: installation, diagnostics: diagnostics)
        let sd = AgentOriginSnapshot.Space(uuid: "sd", id: 5, ordinal: 2, displayID: "display", label: "SD")
        let sql = AgentOriginSnapshot.Space(uuid: "text2sql", id: 4, ordinal: 5, displayID: "display", label: "text2sql")
        let studio = AgentOriginSnapshot.Space(uuid: "studio", id: 3, ordinal: 1, displayID: "display", label: "studio")
        func event(_ kind: String, _ space: AgentOriginSnapshot.Space, turn: String) -> AgentHookEvent {
            .init(agentID: "codex", source: "test", session: "same-session", kind: kind, turn: turn,
                  received: Date(), project: space.label, origin: space.origin, originCapturePolicy: AgentSpaceCapture.policy)
        }
        try transport.enqueue(event("UserPromptSubmit", sql, turn: "sql"))
        try transport.enqueue(event("UserPromptSubmit", sd, turn: "sd"))
        _ = try transport.drain()
        // Deliberately supply the wrong completion-time origin; transport must replace it.
        var stop = event("Stop", sql, turn: "sql")
        stop.origin = studio.origin
        try transport.enqueue(stop)
        try transport.enqueue(event("Stop", sd, turn: "sd"))
        let events = try transport.drain()
        let backend = OriginBackendFixture()
        backend.state = .init(permitted: true, spaces: [studio, sd, sql])
        backend.current = studio.id
        let navigation = AgentOriginNavigation(backend: backend, log: { _ in }, diagnostics: diagnostics, wait: { _ in })
        let registrar = ShortcutRegistrarFixture()
        let suite = "HookTrace." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let presenter = AgentToastPresenter(navigation: navigation,
            shortcut: AgentToastShortcut(defaults: defaults, registrar: registrar), diagnostics: diagnostics)
        defer { presenter.clear() }
        let model = AgentNotificationModel(defaults: defaults, originNavigation: navigation, diagnostics: diagnostics,
            present: { presenter.show($0) }, playSound: {})
        for event in events { model.receive(event) }
        // Both toasts are stacked; the older text2sql one is clicked first.
        XCTAssertEqual(presenter.visible.map(\.title), ["SD", "text2sql"])
        let first = try XCTUnwrap(presenter.visible.first { $0.title == "text2sql" })
        XCTAssertEqual(first.destination, sql.origin)
        await presenter.activate(first)
        await presenter.activate(first) // queued/stale click must not select the next toast
        let second = try XCTUnwrap(presenter.currentNotice)
        XCTAssertEqual(second.title, "SD")
        registrar.fire()
        for _ in 0..<20 where presenter.currentNotice != nil { await Task.yield() }
        XCTAssertEqual(backend.switched, [sql.id, sd.id])
        let rows = try records(url)
        let activations = rows.filter { $0.stage == "toast.activated" }
        XCTAssertEqual(activations.map { $0.fields["input"] }, ["click", "shortcut"])
        XCTAssertEqual(activations.map { $0.fields["destination_uuid"] }, [sql.uuid, sd.uuid])
        XCTAssertEqual(rows.first { $0.stage == "toast.activation_ignored" }?.fields["reason"], "stale_notice")
        for (event, notice) in zip(events, [first, second]) {
            let chain = rows.filter { $0.fields["trace"] == event.traceID }
            for stage in ["context.resolved", "transport.committed", "app.received", "app.delivered", "toast.displayed", "toast.activated", "navigation.requested", "navigation.finished"] {
                XCTAssertTrue(chain.contains { $0.stage == stage }, stage)
            }
            let arrival = try XCTUnwrap(chain.first { $0.stage == "navigation.finished" })
            XCTAssertEqual(arrival.fields["notice"], notice.id.uuidString)
            XCTAssertEqual(arrival.fields["outcome"], "confirmed")
            XCTAssertEqual(arrival.fields["actual_uuid"], notice.destination?.spaceUUID)
        }
    }
}
