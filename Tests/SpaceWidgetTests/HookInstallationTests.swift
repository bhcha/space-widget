import XCTest
@testable import SpaceWidget

final class HookInstallationTests: XCTestCase {
    private var root: URL!
    private let helper = Data("#!/bin/sh\nexit 0\n".utf8)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("hooks ' $dollar `literal` " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func installation(_ agent: LocalAgent = .claude) -> HookInstallation {
        HookInstallation(agent: agent, directory: root.appendingPathComponent(agent.rawValue + " custom"))
    }
    private func write(_ value: [String: Any], _ installation: HookInstallation) throws {
        try FileManager.default.createDirectory(at: installation.directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: installation.file)
    }
    private func read(_ installation: HookInstallation) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: installation.file)) as! [String: Any]
    }
    private func entries(_ installation: HookInstallation, event: String) throws -> [[String: Any]] {
        let document = try read(installation)
        let hooks = document["hooks"] as? [String: Any] ?? [:]
        return (hooks[event] as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    }

    func testBothCustomLocationsPreserveSettingsIdempotencyBackupsAndOwnOnlyRemoval() throws {
        for agent in LocalAgent.allCases {
            let target = installation(agent)
            let original: [String: Any] = ["theme": "dark", "permissions": ["allow": ["Bash(git status)"]],
                "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "echo user hook"]]]],
                          "PreToolUse": [["hooks": [["type": "command", "command": "echo other"]]]]]]
            try write(original, target)
            let bytes = try Data(contentsOf: target.file)
            let backup = try XCTUnwrap(target.install(helperBytes: helper))
            XCTAssertEqual(try Data(contentsOf: backup), bytes)
            let first = try Data(contentsOf: target.file)
            XCTAssertNil(try target.install(helperBytes: helper))
            XCTAssertEqual(try Data(contentsOf: target.file), first)
            XCTAssertEqual(try entries(target, event: "Stop").count, 2)
            XCTAssertEqual(try entries(target, event: "SessionStart").count, 1)
            XCTAssertEqual(target.inspect(), agent == .codex ? .pendingTrust : .awaitingExecution)
            let uninstallBackup = try XCTUnwrap(target.uninstall())
            XCTAssertEqual(try Data(contentsOf: uninstallBackup), first)
            XCTAssertTrue(NSDictionary(dictionary: try read(target)).isEqual(to: original))
            XCTAssertNil(try target.uninstall())
            XCTAssertEqual(target.inspect(), .installable)
            let attrs = try FileManager.default.attributesOfItem(atPath: backup.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testRemovalPreservesSiblingHandlersAddedToOwnedGroupAndLookalikes() throws {
        let target = installation()
        try target.install(helperBytes: helper)
        var document = try read(target)
        var hooks = document["hooks"] as! [String: Any]
        let foreign = ["type": "command", "command": "echo SpaceWidget " + target.command(for: "Stop")]
        hooks["Stop"] = [["hooks": [target.handler(for: "Stop"), foreign], "matcher": "", "userNote": "keep"]]
        document["hooks"] = hooks
        try write(document, target)
        try target.uninstall()
        XCTAssertEqual(try entries(target, event: "Stop").count, 1)
        XCTAssertEqual(try entries(target, event: "Stop")[0]["command"] as? String, foreign["command"])
        let group = ((try read(target)["hooks"] as! [String: Any])["Stop"] as! [[String: Any]])[0]
        XCTAssertEqual(group["userNote"] as? String, "keep")
    }

    func testReadOnlyInspectionAndMissingUninstallHaveNoFilesystemEffects() throws {
        let target = installation()
        XCTAssertEqual(target.inspect(), .installable)
        XCTAssertNil(try target.uninstall())
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.directory.path))
    }

    func testMissingHelperRestoresOnlyRecordedBytesAndNeverReplacesTrustIdentity() throws {
        for agent in LocalAgent.allCases {
            let target = installation(agent)
            try target.install(helperBytes: helper)
            let originalConfig = try Data(contentsOf: target.file)
            let originalHash = try Data(contentsOf: target.helperHash)
            try FileManager.default.removeItem(at: target.helper)
            XCTAssertThrowsError(try target.install(helperBytes: Data("different executable".utf8)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.helper.path))
            XCTAssertEqual(try Data(contentsOf: target.file), originalConfig)
            XCTAssertEqual(try Data(contentsOf: target.helperHash), originalHash)
            XCTAssertNil(try target.install(helperBytes: helper))
            XCTAssertEqual(try Data(contentsOf: target.helper), helper)
            XCTAssertEqual(try Data(contentsOf: target.helperHash), originalHash)
            try FileManager.default.removeItem(at: target.helper)
            try FileManager.default.removeItem(at: target.helperHash)
            XCTAssertThrowsError(try target.install(helperBytes: helper))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.helper.path))
            XCTAssertEqual(try Data(contentsOf: target.file), originalConfig)
            try FileManager.default.removeItem(at: target.support)
            XCTAssertThrowsError(try target.install(helperBytes: helper), "Existing hook references also prevent new identity creation")
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.helper.path))
        }
    }

    func testMalformedConfigAndUnsupportedShapesFailWithoutReplacement() throws {
        let target = installation()
        for bytes in [Data("broken json".utf8), Data("[]".utf8), Data("{\"hooks\":false}".utf8),
                      Data("{\"hooks\":{\"Stop\":{}}}".utf8), Data("{\"hooks\":{\"Stop\":[{\"hooks\":false}]}}".utf8)] {
            try FileManager.default.createDirectory(at: target.directory, withIntermediateDirectories: true)
            try bytes.write(to: target.file)
            XCTAssertThrowsError(try target.install(helperBytes: helper))
            XCTAssertThrowsError(try target.uninstall())
            XCTAssertEqual(try Data(contentsOf: target.file), bytes)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.support.path))
    }

    func testConcurrentExternalEditAndInjectedFailurePreserveConfig() throws {
        let target = installation()
        try write(["keep": 1], target)
        let original = try Data(contentsOf: target.file)
        XCTAssertThrowsError(try target.install(helperBytes: helper, beforeCommit: { throw CocoaError(.fileWriteUnknown) }))
        XCTAssertEqual(try Data(contentsOf: target.file), original)
        let edited = Data("{\"new_external_change\":true}".utf8)
        XCTAssertThrowsError(try target.install(helperBytes: helper, beforeCommit: { try edited.write(to: target.file) }))
        XCTAssertEqual(try Data(contentsOf: target.file), edited)
        let names = try FileManager.default.contentsOfDirectory(atPath: target.directory.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".spacewidget-") || $0.contains("backup") })
    }

    func testSymlinksAndForeignHelperDirectoryAreNotOverwritten() throws {
        let target = installation()
        try FileManager.default.createDirectory(at: target.directory, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("external")
        let original = Data("{}".utf8)
        try original.write(to: external)
        try FileManager.default.createSymbolicLink(at: target.file, withDestinationURL: external)
        XCTAssertThrowsError(try target.install(helperBytes: helper))
        XCTAssertEqual(try Data(contentsOf: external), original)
        try FileManager.default.removeItem(at: target.file)
        try FileManager.default.createDirectory(at: target.support, withIntermediateDirectories: true)
        let foreign = target.support.appendingPathComponent("mine")
        try original.write(to: foreign)
        XCTAssertThrowsError(try target.install(helperBytes: helper))
        XCTAssertEqual(try Data(contentsOf: foreign), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.file.path))
    }

    func testHelperIsDurableImmutableExecutableAndInvocationIsShellSafeAndNonblocking() throws {
        let target = installation()
        let script = Data("#!/bin/sh\n[ \"$1\" = '--spacewidget-hook' ] || exit 3\n[ \"$2\" = 'claude' ] || exit 4\nprintf '%s' \"$3\" > \"$3/seen-path\"\necho must-not-reach-agent\nexit 2\n".utf8)
        try target.install(helperBytes: script)
        try target.install(helperBytes: Data("different binary".utf8))
        XCTAssertEqual(try Data(contentsOf: target.helper), script, "Do not change executable behind approved command")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: target.helper.path))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", target.command(for: "Stop")]
        process.currentDirectoryURL = root
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try output.fileHandleForWriting.close()
        XCTAssertEqual(output.fileHandleForReading.readDataToEndOfFile(), Data())
        XCTAssertEqual(try String(contentsOf: target.directory.appendingPathComponent("seen-path")), target.directory.path)
        try FileManager.default.removeItem(at: target.helper)
        let missing = Process(); missing.executableURL = URL(fileURLWithPath: "/bin/sh")
        missing.arguments = ["-c", target.command(for: "Stop")]
        try missing.run(); missing.waitUntilExit()
        XCTAssertEqual(missing.terminationStatus, 0)
    }

    private func receive(_ target: HookInstallation, payload: String) throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
        try pipe.fileHandleForWriting.close()
        HookInstallationReceiver.run(arguments: [target.helper.path, "--spacewidget-hook", target.agent.rawValue,
            target.directory.path, "Stop"], input: pipe.fileHandleForReading.fileDescriptor)
        try pipe.fileHandleForReading.close()
    }

    func testCodexStopReturnsNeutralJSONEvenWhenHelperFailsOrIsMissing() throws {
        let target = installation(.codex)
        try target.install(helperBytes: Data("#!/bin/sh\necho private-payload\necho private-error >&2\nexit 7\n".utf8))
        for missing in [false, true] {
            if missing { try FileManager.default.removeItem(at: target.helper) }
            let process = Process()
            let output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", target.command(for: "Stop")]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output; process.standardError = errors
            try process.run(); process.waitUntilExit()
            try output.fileHandleForWriting.close(); try errors.fileHandleForWriting.close()
            XCTAssertEqual(process.terminationStatus, 0)
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertTrue(object.isEmpty, "No decision/continue fields may alter the agent response")
            XCTAssertTrue(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private"))
        }
    }

    @MainActor
    func testDesktopOnlyExplicitInstallationAwaitsRealCallbackAndPreservesUnknownCapability() async throws {
        for agent in LocalAgent.allCases {
            let target = installation(agent)
            let result = AgentDetection(agent: agent, configurationDirectory: target.directory,
                runtimes: [.init(scope: .desktop, location: root.appendingPathComponent("Agent.app"),
                                 version: "2026.10", capability: .unknown("Code 사용 여부 미확인"))], issues: [])
            let model = HookInstallationModel(helperBytes: { self.helper })
            model.refresh([result])
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.file.path))
            await model.install(result)
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.file.path))
            XCTAssertEqual(model.states[agent], agent == .codex ? .pendingTrust : .awaitingExecution)
            XCTAssertFalse(result.runtimes.contains { $0.capability == .supported })
            await model.uninstall(result)
            XCTAssertEqual(target.inspect(), .installable)
        }
    }

    func testExecutionReceiptRequiresCurrentConfigAndNeverGrantsCodexTrust() throws {
        for agent in LocalAgent.allCases {
            let target = installation(agent)
            try target.install(helperBytes: helper)
            try receive(target, payload: "{\"session_id\":\"fixture\",\"hook_event_name\":\"Stop\",\"prompt\":\"DO NOT STORE\",\"transcript_path\":\"/never/open\"}")
            XCTAssertEqual(target.inspect(), agent == .codex ? .pendingTrust : .connected)
            let receipt = try String(contentsOf: target.receipt)
            XCTAssertFalse(receipt.contains("DO NOT STORE")); XCTAssertFalse(receipt.contains("transcript"))
            XCTAssertEqual(installation(agent).inspect(), target.inspect(), "Inspection survives restart")
            var changed = try read(target); changed["new_setting"] = true; try write(changed, target)
            XCTAssertEqual(target.inspect(), agent == .codex ? .pendingTrust : .awaitingExecution)
        }
    }

    func testInvalidRecursiveAndSubagentInputsDoNotConfirmConnection() throws {
        let target = installation()
        try target.install(helperBytes: helper)
        for payload in ["{}", "broken", "{\"session_id\":\"s\",\"hook_event_name\":\"SubagentStop\"}",
                        "{\"session_id\":\"s\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":true}",
                        "{\"session_id\":\"s\",\"hook_event_name\":\"Stop\",\"agent_id\":\"child\"}"] {
            try receive(target, payload: payload)
            XCTAssertEqual(target.inspect(), .awaitingExecution)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.receipt.path))
        }
    }

    func testDisabledHooksAndPartialInstallationDoNotShowConnected() throws {
        let target = installation()
        try target.install(helperBytes: helper)
        var object = try read(target); object["disableAllHooks"] = true; try write(object, target)
        guard case .failure = target.inspect() else { return XCTFail("Disabled hooks") }
        object.removeValue(forKey: "disableAllHooks")
        var hooks = object["hooks"] as! [String: Any]; hooks.removeValue(forKey: "Stop")
        object["hooks"] = hooks; try write(object, target)
        guard case .failure = target.inspect() else { return XCTFail("Partial installation") }
        try target.install(helperBytes: helper)
        XCTAssertEqual(target.inspect(), .awaitingExecution)
    }

    func testUninstallReinstallCannotReuseOldExecutionAndHelperTamperingIsDetected() throws {
        let target = installation()
        try target.install(helperBytes: helper)
        try receive(target, payload: "{\"session_id\":\"s\",\"hook_event_name\":\"Stop\"}")
        XCTAssertEqual(target.inspect(), .connected)
        try target.uninstall()
        try target.install(helperBytes: helper)
        XCTAssertEqual(target.inspect(), .awaitingExecution)
        try Data("altered".utf8).write(to: target.helper)
        guard case .failure = target.inspect() else { return XCTFail("Tampered helper") }
        XCTAssertThrowsError(try target.install(helperBytes: helper))
        try target.uninstall() // Config removal still works with a broken helper.
        XCTAssertEqual(target.inspect(), .installable)
    }

    func testDirectoryLockRejectsCompetingInstallerAndKeepsAtomicReaderSnapshot() throws {
        let target = installation()
        try write(["keep": true], target)
        let before = try Data(contentsOf: target.file)
        try target.install(helperBytes: helper, beforeCommit: {
            XCTAssertEqual(try Data(contentsOf: target.file), before)
            XCTAssertThrowsError(try target.uninstall()) { error in
                guard case HookInstallationError.busy = error else { return XCTFail("\(error)") }
            }
        })
        XCTAssertNoThrow(try read(target))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: target.directory.path)
            .contains { $0.hasPrefix(".spacewidget-") })
    }

    func testNativeDurableHelperExecutesWithoutAppStartupAndBoundsInput() throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SpaceWidget")
        let target = installation()
        try target.install(helperBytes: Data(contentsOf: binary))
        let input = root.appendingPathComponent("input.json")
        try Data("{\"session_id\":\"fixture\",\"hook_event_name\":\"Stop\"}".utf8).write(to: input)
        let process = Process(); process.executableURL = target.helper
        process.arguments = ["--spacewidget-hook", "claude", target.directory.path, "Stop"]
        process.standardInput = try FileHandle(forReadingFrom: input)
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try output.fileHandleForWriting.close()
        XCTAssertEqual(output.fileHandleForReading.readDataToEndOfFile(), Data())
        XCTAssertEqual(target.inspect(), .connected)
        try FileManager.default.removeItem(at: target.receipt)
        try Data(repeating: 65, count: 262_145).write(to: input)
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        HookInstallationReceiver.run(arguments: [target.helper.path, "--spacewidget-hook", "claude", target.directory.path, "Stop"],
            input: handle.fileDescriptor)
        XCTAssertEqual(target.inspect(), .awaitingExecution)
    }

    @MainActor
    func testModelHasNoStartupInstallAndRequiresSupportedRuntimeAndExplicitAction() async throws {
        let target = installation()
        let missing = AgentDetection(agent: .claude, configurationDirectory: target.directory, runtimes: [], issues: [])
        var helperReads = 0
        let model = HookInstallationModel { helperReads += 1; return self.helper }
        model.refresh([missing])
        XCTAssertEqual(helperReads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.directory.path))
        await model.install(missing)
        XCTAssertEqual(helperReads, 0)
        guard case .failure = model.states[.claude] else { return XCTFail("Cannot install unsupported runtime") }
        let supported = AgentDetection(agent: .claude, configurationDirectory: target.directory,
            runtimes: [AgentRuntime(scope: .cli, location: root, version: "fixture", capability: .supported)], issues: [])
        let task = Task { await model.install(supported) }
        while !model.busy { await Task.yield() }
        XCTAssertEqual(model.states[.claude], .installing)
        await model.install(supported) // no overlapping mutations
        await task.value
        XCTAssertEqual(helperReads, 1)
        XCTAssertEqual(model.states[.claude], .awaitingExecution)
        await model.uninstall(supported)
        XCTAssertEqual(model.states[.claude], .uninstalled)
        XCTAssertFalse(model.busy)
    }
}

extension HookInstallationTests {
    func testExplicitUpgradePreservesOldBinaryAndRequiresNewCommandTrust() throws {
        for agent in LocalAgent.allCases {
          for version in [1, 2, 3, 4, 5] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let old = HookInstallation(agent: agent, directory: root, helperVersion: version)
            let current = HookInstallation(agent: agent, directory: root)
            let oldBytes = Data("old version".utf8), newBytes = Data("new version".utf8)
            try old.install(helperBytes: oldBytes)
            XCTAssertEqual(current.inspect(), .updateAvailable)
            XCTAssertNotEqual(old.command(for: "Stop"), current.command(for: "Stop"))
            let backup = try XCTUnwrap(current.install(helperBytes: newBytes))
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
            XCTAssertEqual(try Data(contentsOf: old.helper), oldBytes)
            XCTAssertEqual(try Data(contentsOf: current.helper), newBytes)
            let config = try String(contentsOf: current.file)
            XCTAssertFalse(config.contains("receiver-v\(version)"))
            XCTAssertTrue(config.contains("receiver-v6"))
            XCTAssertTrue(config.contains("UserPromptSubmit"))
            XCTAssertEqual(current.inspect(), agent == .codex ? .pendingTrust : .awaitingExecution)
            XCTAssertNil(try current.install(helperBytes: newBytes))
            try current.uninstall()
            XCTAssertEqual(current.inspect(), .installable)
          }
        }
    }

    func testUpgradeDoesNotUseOlderIntegrityEvidenceToBypassDamagedV2() throws {
        let directory = root.appendingPathComponent("upgrade")
        let v1 = HookInstallation(agent: .claude, directory: directory, helperVersion: 1)
        let v2 = HookInstallation(agent: .claude, directory: directory, helperVersion: 2)
        let current = HookInstallation(agent: .claude, directory: directory)
        try v1.install(helperBytes: helper)
        try v2.install(helperBytes: helper)
        try Data("changed".utf8).write(to: v2.helper)
        let configuration = try Data(contentsOf: current.file)
        XCTAssertThrowsError(try current.install(helperBytes: helper))
        XCTAssertEqual(try Data(contentsOf: current.file), configuration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.helper.path))
    }
}
