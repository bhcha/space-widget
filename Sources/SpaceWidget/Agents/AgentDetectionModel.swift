import Foundation
import Combine

@MainActor
final class AgentDetectionModel: ObservableObject {
    @Published private(set) var results: [AgentDetection] = []
    @Published private(set) var isScanning = false
    private let scan: () async -> [AgentDetection]

    init(scan: @escaping () async -> [AgentDetection] = {
        let detector = AgentDetector.system()
        return await Task.detached(priority: .utility) { detector.scan() }.value
    }) {
        self.scan = scan
    }

    /// One in-flight scan; replaces prior results so removed installations don't linger.
    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        results = await scan()
    }
}
