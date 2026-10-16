import XCTest
import AppKit
import SwiftUI
@testable import SpaceWidget

final class AgentSettingsViewTests: XCTestCase {
    private func detection(_ agent: LocalAgent = .codex, directory: URL,
                           capability: HookCapability = .supported, found: Bool = true,
                           issues: [String] = []) -> AgentDetection {
        AgentDetection(agent: agent, configurationDirectory: directory,
            runtimes: found ? [AgentRuntime(scope: .cli, location: directory.appendingPathComponent("agent"),
                                           version: "1.0.0", capability: capability)] : [], issues: issues)
    }

    func testCardActionsRespectCapabilityBusyAndLifecycle() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let supported = detection(directory: directory)
        for state in [HookInstallationState.installable, .updateAvailable, .uninstalled, .failure("권한을 확인하세요")] {
            let presentation = AgentCardPresentation(result: supported, state: state, busy: false)
            XCTAssertTrue(presentation.offersInstall)
            XCTAssertTrue(presentation.canInstall)
        }
        for state in [HookInstallationState.pendingTrust, .awaitingExecution, .connected] {
            let presentation = AgentCardPresentation(result: supported, state: state, busy: false)
            XCTAssertFalse(presentation.offersInstall)
            XCTAssertTrue(presentation.offersUninstall)
        }
        let installing = AgentCardPresentation(result: supported, state: .installing, busy: true)
        XCTAssertFalse(installing.canInstall)
        XCTAssertFalse(installing.offersInstall)
        XCTAssertFalse(installing.offersUninstall)
        XCTAssertEqual(installing.status, "Installing...")
        for result in [detection(directory: directory, capability: .unknown("버전 미확인")),
                       detection(directory: directory, capability: .unsupported("지원 안 됨")),
                       detection(directory: directory, found: false),
                       detection(directory: directory, issues: ["설정 오류"])] {
            XCTAssertFalse(AgentCardPresentation(result: result, state: .installable, busy: false).canInstall)
        }
        XCTAssertEqual(AgentCardPresentation(result: supported, state: .updateAvailable, busy: false).installTitle, "Update Hooks")
        XCTAssertEqual(AgentCardPresentation(result: supported, state: .failure("저장 실패"), busy: false).installTitle, "Retry")
        XCTAssertTrue(AgentCardPresentation(result: supported, state: .pendingTrust, busy: false).status.contains("Check approval"))
        XCTAssertEqual(AgentCardPresentation(result: detection(directory: directory, found: false), state: .installable, busy: false).status, "Not found")
    }

    func testDesktopOnlySetupAvailableWithoutClaimingCapabilityOrConnection() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for agent in LocalAgent.allCases {
            let result = AgentDetection(agent: agent, configurationDirectory: directory,
                runtimes: [.init(scope: .desktop, location: directory.appendingPathComponent("Agent.app"),
                                 version: "2026.10", capability: .unknown("로컬 Code 확인 필요"))], issues: [])
            let presentation = AgentCardPresentation(result: result, state: .installable, busy: false)
            XCTAssertTrue(presentation.canInstall)
            XCTAssertFalse(result.runtimes.contains { $0.capability == .supported })
            XCTAssertFalse(presentation.status.contains("Connected"))
            XCTAssertTrue(presentation.status.contains("verification"))
            XCTAssertFalse(AgentCardPresentation(result: result, state: .installable, busy: true).canInstall)
        }
    }

    @MainActor
    func testNativeSettingsRenderReadOnlyInLightAndDark() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "SpaceWidgetSettingsFixture." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let results = LocalAgent.allCases.map { detection($0, directory: directory.appendingPathComponent($0.rawValue)) }
        let model = AgentDetectionModel(scan: { results })
        await model.rescan()
        let hooks = HookInstallationModel(helperBytes: { XCTFail("Rendering must never install"); return Data() })
        hooks.refresh(results)
        let notifications = AgentNotificationModel(defaults: defaults,
            present: { _ in XCTFail("Rendering must never notify") }, playSound: { XCTFail("Rendering must never play sound") })
        for (name, appearance, height) in [("light", NSAppearance.Name.aqua, 660.0), ("dark", .darkAqua, 660.0), ("full", .aqua, 860.0)] {
            let view = NSHostingView(rootView: AgentDetectionView(model: model, hooks: hooks, notifications: notifications,
                shortcut: AgentToastShortcut(defaults: defaults, registrar: ShortcutRegistrarFixture())))
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(x: 0, y: 0, width: 580, height: height)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 1000)
            if let path = ProcessInfo.processInfo.environment["SPACEWIDGET_SETTINGS_QA_DIR"] {
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("settings-\(name).png"))
            }
            window.orderOut(nil)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertEqual(LocalAgent.allCases.map(\.provider), ["OpenAI", "Anthropic"])
    }

    @MainActor
    func testNativeCardsRenderEveryActionableState() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let states: [HookInstallationState] = [.installable, .updateAvailable, .installing, .failure("Cannot save the configuration. Check the file permissions."), .pendingTrust, .awaitingExecution, .connected, .uninstalled]
        for state in states {
            let view = NSHostingView(rootView: AgentSettingsCard(result: detection(directory: directory),
                state: state, busy: state == .installing,
                install: { XCTFail("Render invoked install") }, uninstall: { XCTFail("Render invoked uninstall") },
                trustHelp: {}, preview: {}))
            view.frame = NSRect(x: 0, y: 0, width: 532, height: 260)
            view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(view.fittingSize.height, 60)
            XCTAssertLessThan(view.fittingSize.height, 260, "Card clipped for \(state)")
        }
    }
}
