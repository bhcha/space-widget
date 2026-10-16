import XCTest
@testable import SpaceWidget

final class AgentDetectionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func executable(_ name: String, body: String = "exit 0") throws -> URL {
        let file = root.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
    private func detector(_ probe: @escaping (URL, [String]) throws -> AgentProbeResult = { _, _ in
        XCTFail("Missing installation must not launch a probe")
        return AgentProbeResult(status: 1, output: "")
    }) -> AgentDetector {
        AgentDetector(home: root, environment: [:], executableDirectories: [root],
            applicationDirectories: [root], registeredApplication: { _ in nil }, probe: probe)
    }
    private func app(_ agent: LocalAgent, name: String, version: String = "1.2.3") throws -> URL {
        let app = root.appendingPathComponent(name + ".app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": agent.bundleID, "CFBundleShortVersionString": version
        ], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    func testMissingInstallationsAndProviders() {
        let results = detector().scan()
        XCTAssertEqual(results.map(\.agent.provider), ["OpenAI", "Anthropic"])
        XCTAssertTrue(results.allSatisfy { $0.runtimes.isEmpty && $0.readiness == "Not found" })
    }

    func testClaudeSupportedAndUnsupportedVersions() throws {
        _ = try executable("claude")
        for (version, supported) in [("1.0.37", false), ("1.0.41", false), ("1.0.61", false),
                                      ("1.0.62", true), ("2.1.0", true)] {
            let result = detector { _, args in
                XCTAssertEqual(args, ["--version"])
                return AgentProbeResult(status: 0, output: "\(version) (Claude Code)\n")
            }.detect(.claude)
            XCTAssertEqual(result.runtimes.first?.capability == .supported, supported, version)
            XCTAssertEqual(result.runtimes.first?.scope, .cli)
            XCTAssertFalse(result.readiness.contains("Connected"))
        }
    }

    func testCodexFeatureCapabilityIsNotTrustOrEnabledEvidence() throws {
        _ = try executable("codex")
        for feature in ["hooks", "codex_hooks"] {
            let result = detector { _, args in
                AgentProbeResult(status: 0, output: args == ["--version"]
                    ? "codex-cli 0.130.0" : "\(feature) experimental false\n")
            }.detect(.codex)
            XCTAssertEqual(result.runtimes.first?.capability, .supported)
            XCTAssertTrue(result.readiness.contains("not verified"))
        }
        let noFeature = detector { _, args in
            AgentProbeResult(status: 0, output: args == ["--version"] ? "codex-cli 0.1.0" : "other stable true")
        }.detect(.codex)
        guard case .unknown = noFeature.runtimes[0].capability else { return XCTFail("No hook evidence") }
    }

    func testProbeFailureAndUnrecognizedVersionStayInstalledButUnknown() throws {
        _ = try executable("codex")
        for reply in [AgentProbeResult(status: 1, output: "codex-cli 0.130.0"),
                      AgentProbeResult(status: 0, output: "another program 9.0.0"),
                      AgentProbeResult(status: 0, output: "codex-cli 0.130.0-beta.1")] {
            let runtime = detector { _, _ in reply }.detect(.codex).runtimes[0]
            XCTAssertNil(runtime.version)
            guard case .unknown = runtime.capability else { return XCTFail("Should remain unknown") }
        }
        let runtime = detector { _, _ in throw AgentProbeError.timedOut }.detect(.codex).runtimes[0]
        guard case .unknown = runtime.capability else { return XCTFail("Timeout must not mean absent") }
    }

    func testDesktopClaudeChatDoesNotImplyCodeAndCLIDoesNotUpgradeDesktop() throws {
        let desktop = try app(.claude, name: "Renamed Claude")
        var scan = detector()
        scan.registeredApplication = { _ in desktop }
        var results = scan.detect(.claude)
        XCTAssertEqual(results.runtimes.count, 1)
        XCTAssertEqual(results.runtimes[0].scope, .desktop)
        XCTAssertEqual(results.runtimes[0].version, "1.2.3")
        guard case .unknown(let reason) = results.runtimes[0].capability else { return XCTFail("Chat is not Code") }
        XCTAssertTrue(reason.contains("Regular Chat is not supported"))
        _ = try executable("claude")
        scan.probe = { _, _ in AgentProbeResult(status: 0, output: "2.1.0 (Claude Code)") }
        results = scan.detect(.claude)
        XCTAssertEqual(results.runtimes.count, 2)
        XCTAssertEqual(results.runtimes[0].capability, .supported)
        XCTAssertEqual(results.runtimes[1].capability, .unknown(reason))
    }

    func testDesktopCodexAndConfigOverridesAndSymlinkDeduplication() throws {
        _ = try app(.codex, name: "Codex Renamed", version: "2026.10")
        _ = try executable("codex")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        var scan = detector { _, args in
            AgentProbeResult(status: 0, output: args == ["--version"] ? "codex-cli 0.130.0" : "hooks stable true")
        }
        scan.executableDirectories += [alias]
        scan.environment = ["CODEX_HOME": root.appendingPathComponent("custom codex").path,
                            "CLAUDE_CONFIG_DIR": root.appendingPathComponent("custom claude").path]
        let results = scan.scan()
        XCTAssertEqual(results[0].runtimes.count, 2)
        XCTAssertEqual(results[0].runtimes[1].version, "2026.10")
        XCTAssertEqual(results[0].configurationDirectory.lastPathComponent, "custom codex")
        XCTAssertEqual(results[1].configurationDirectory.lastPathComponent, "custom claude")
        XCTAssertFalse(FileManager.default.fileExists(atPath: results[0].configurationDirectory.path))
    }

    func testActualFixtureProbeIsIsolatedAndHandlesSpacesAndArguments() throws {
        let fixture = try executable("agent with ' quotes", body: """
        test "$1" = '--version' || exit 3
        test "$HOME" = "$CODEX_HOME" || exit 4
        test "$HOME" = "$CLAUDE_CONFIG_DIR" || exit 5
        test "$HOME" -ef "$PWD" || exit 6
        touch "$CODEX_HOME/probe-marker"
        printf '2.1.0 (Claude Code)\\n'
        """)
        let result = try AgentCommandProbe().run(fixture, ["--version"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "2.1.0 (Claude Code)\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("probe-marker").path))
        let failure = try AgentCommandProbe().run(fixture, ["wrong argument"])
        XCTAssertEqual(failure.status, 3)
    }

    func testActualFixtureTimeoutOutputBoundAndLaunchFailure() throws {
        let hanging = try executable("hanging", body: "while :; do :; done")
        XCTAssertThrowsError(try AgentCommandProbe(timeout: 0.1).run(hanging, [])) { error in
            guard case AgentProbeError.timedOut = error else { return XCTFail("\(error)") }
        }
        let noisy = try executable("noisy", body: "while :; do printf '1234567890'; done")
        XCTAssertThrowsError(try AgentCommandProbe(outputLimit: 128).run(noisy, [])) { error in
            guard case AgentProbeError.excessiveOutput = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try AgentCommandProbe().run(root.appendingPathComponent("missing"), []))
    }

    func testFinderEnvironmentDiscoversNVMAndRunsSiblingInterpreter() throws {
        let bin = root.appendingPathComponent(".nvm/versions/node/v22.22.1/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let launcher = bin.appendingPathComponent("codex")
        let interpreter = bin.appendingPathComponent("spacewidget-fixture-node")
        try "#!/bin/sh\nspacewidget-fixture-node \"$@\"\n".write(to: launcher, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        if [ "$1" = '--version' ]; then
          printf 'codex-cli 0.162.1\\n'
        elif [ "$1" = 'features' ] && [ "$2" = 'list' ]; then
          printf 'hooks stable true\\n'
        else
          exit 2
        fi
        """.write(to: interpreter, atomically: true, encoding: .utf8)
        for file in [launcher, interpreter] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let environment = ["PATH": ".:/usr/bin:/bin"]
        let paths = AgentDetector.executableSearchDirectories(home: root, environment: environment)
        XCTAssertTrue(paths.map(\.path).contains(bin.path))
        XCTAssertTrue(paths.allSatisfy { $0.path.hasPrefix("/") })
        var scan = detector { executable, arguments in
            try AgentCommandProbe(inheritedPath: "/usr/bin:/bin").run(executable, arguments)
        }
        // Restrict this integration fixture to its temporary home, never installed agents.
        scan.executableDirectories = paths.filter { $0.path.hasPrefix(root.path + "/") }
        let result = scan.detect(.codex)
        XCTAssertEqual(result.runtimes.count, 1)
        XCTAssertEqual(result.runtimes.first?.location, launcher)
        XCTAssertEqual(result.runtimes.first?.version, "codex-cli 0.162.1")
        XCTAssertEqual(result.runtimes.first?.capability, .supported)
    }

    func testCustomNVMDirectoryUsesNewestBoundedVersionCandidates() throws {
        let nvm = root.appendingPathComponent("custom nvm")
        for version in 1...34 {
            try FileManager.default.createDirectory(at: nvm.appendingPathComponent("versions/node/v22.0.\(version)/bin"),
                                                    withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: nvm.appendingPathComponent("versions/node/unrelated/bin"),
                                                withIntermediateDirectories: true)
        let paths = AgentDetector.executableSearchDirectories(home: root,
            environment: ["NVM_DIR": nvm.path, "PATH": "/usr/bin:/bin"])
            .filter { $0.path.hasPrefix(nvm.path + "/") }
        XCTAssertEqual(paths.count, 32)
        XCTAssertEqual(paths.first?.deletingLastPathComponent().lastPathComponent, "v22.0.34")
        XCTAssertFalse(paths.contains { $0.path.contains("unrelated") })
    }

    @MainActor
    func testRescanReplacesOldResultsAndDoesNotOverlap() async {
        var calls = 0
        let model = AgentDetectionModel {
            calls += 1
            try? await Task.sleep(nanoseconds: 20_000_000)
            return calls == 1 ? [AgentDetection(agent: .codex, configurationDirectory: self.root,
                runtimes: [], issues: [])] : []
        }
        let first = Task { await model.rescan() }
        while !model.isScanning { await Task.yield() }
        await model.rescan()
        await first.value
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.results.count, 1)
        await model.rescan()
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(model.results.isEmpty)
    }
}
