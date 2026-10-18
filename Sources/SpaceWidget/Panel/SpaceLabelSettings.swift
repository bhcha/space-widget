import Combine
import Foundation

final class SpaceLabelSettings: ObservableObject {
    static let shared = SpaceLabelSettings()
    private let defaults: UserDefaults
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: "showSpaceNameOnSwitch") }
    }
    @Published private(set) var previewIssue: String?
    var onPreview: (() -> Bool)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: "showSpaceNameOnSwitch") as? Bool ?? true
    }

    func preview() {
        guard isEnabled else { return }
        previewIssue = onPreview?() == true ? nil : "Preview is unavailable on this display. Leave full screen and try again."
    }
}

/// A display's first observation is a baseline, including after reconnect.
/// Ordinal/name/focus changes never count as a different desktop.
struct SpaceLabelTransitionTracker {
    private(set) var previous: ActiveSpace?
    private var leftDesktop = false

    init(initialSpace: ActiveSpace? = nil) {
        previous = initialSpace.flatMap { $0.id == 0 ? nil : $0 }
    }

    mutating func observe(_ space: ActiveSpace?) -> Bool {
        guard let space, space.id != 0 else {
            leftDesktop = previous != nil
            return false
        }
        defer { previous = space; leftDesktop = false }
        guard let previous else { return false }
        let same: Bool
        if let a = previous.uuid, !a.isEmpty, let b = space.uuid, !b.isEmpty {
            same = a == b
        } else {
            same = previous.id == space.id
        }
        return leftDesktop || !same
    }
}
