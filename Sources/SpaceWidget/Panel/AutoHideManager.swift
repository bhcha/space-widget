import Foundation
import Combine

final class AutoHideManager: ObservableObject {
    private static let key = "autoHideEnabled"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.key)
            isBarVisible = !isEnabled
        }
    }
    @Published var isBarVisible: Bool

    init() {
        let enabled = UserDefaults.standard.bool(forKey: Self.key)
        self.isEnabled = enabled
        self.isBarVisible = !enabled
    }

    func toggle() {
        isEnabled.toggle()
    }

    func showBar() {
        isBarVisible = true
    }

    func hideBar() {
        isBarVisible = false
    }
}
