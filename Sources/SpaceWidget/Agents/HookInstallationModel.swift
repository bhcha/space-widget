import Foundation
import Combine

@MainActor
final class HookInstallationModel: ObservableObject {
    @Published private(set) var states: [LocalAgent: HookInstallationState] = [:]
    @Published private(set) var backups: [LocalAgent: URL] = [:]
    @Published private(set) var busy = false
    private let helperBytes: () throws -> Data

    init(helperBytes: @escaping () throws -> Data = {
        guard let executable = Bundle.main.executableURL else {
            throw HookInstallationError.invalid("Cannot find the application executable.")
        }
        return try Data(contentsOf: executable)
    }) { self.helperBytes = helperBytes }

    func refresh(_ results: [AgentDetection]) {
        guard !busy else { return }
        for result in results {
            states[result.agent] = HookInstallation(agent: result.agent, directory: result.configurationDirectory).inspect()
        }
    }

    /// Invoked only by the runtime button. Detection and startup cannot reach this method.
    func install(_ result: AgentDetection) async {
        guard !busy else { return }
        guard result.allowsHookSetup else {
            states[result.agent] = .failure("Check the installed app or supported CLI and its configuration location.")
            return
        }
        busy = true
        states[result.agent] = .installing
        defer { busy = false }
        do {
            let bytes = try helperBytes()
            let installation = HookInstallation(agent: result.agent, directory: result.configurationDirectory)
            let backup = try await Task.detached(priority: .utility) { try installation.install(helperBytes: bytes) }.value
            if let backup { backups[result.agent] = backup }
            states[result.agent] = installation.inspect()
        } catch { states[result.agent] = .failure(error.localizedDescription) }
    }

    func uninstall(_ result: AgentDetection) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let installation = HookInstallation(agent: result.agent, directory: result.configurationDirectory)
        do {
            let backup = try await Task.detached(priority: .utility) { try installation.uninstall() }.value
            if let backup { backups[result.agent] = backup }
            states[result.agent] = .uninstalled
        } catch { states[result.agent] = .failure(error.localizedDescription) }
    }
}
