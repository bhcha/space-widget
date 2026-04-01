import Foundation
import Combine

/// Writes the current dock state to ~/.config/space-dock/state.json for CLI scripts.
final class StateWriter {

    private let stateURL: URL
    private let queue = DispatchQueue(label: "com.spacedock.statewriter", qos: .utility)
    private var pendingWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    // Minimum interval between writes (1 second)
    private let debounceInterval: TimeInterval = 1.0

    init(stateURL: URL? = nil) {
        self.stateURL = stateURL ?? ConfigManager.configDir.appendingPathComponent("state.json")
    }

    // MARK: - Combine Subscription

    /// Subscribe to a SpaceEngine snapshot publisher and write state on each change.
    func subscribe(to publisher: Published<DockSnapshot>.Publisher) {
        publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard snapshot.space.id != 0 else { return }
                self?.write(
                    currentSpace: snapshot.spaceNumber,
                    spaceID: snapshot.spaceID,
                    spaceLabel: snapshot.spaceLabel,
                    apps: snapshot.appNames
                )
            }
            .store(in: &cancellables)
    }

    // MARK: - Write

    /// Schedules a debounced state write. At most once per second.
    func write(currentSpace: Int, spaceID: UInt64, spaceLabel: String, apps: [String]) {
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performWrite(currentSpace: currentSpace, spaceID: spaceID, spaceLabel: spaceLabel, apps: apps)
        }
        pendingWorkItem = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    // MARK: - Private

    private func performWrite(currentSpace: Int, spaceID: UInt64, spaceLabel: String, apps: [String]) {
        let payload: [String: AnyHashable] = [
            "current_space": currentSpace,
            "space_id": spaceID,
            "space_label": spaceLabel,
            "apps": apps
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            NSLog("[StateWriter] Failed to serialize state")
            return
        }

        do {
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("[StateWriter] Write failed: %@", error.localizedDescription)
        }
    }
}
