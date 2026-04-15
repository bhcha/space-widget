import Foundation

struct OverlapDetection: Codable, Equatable {
    var enabled: Bool
    var minIcons: Int
    var reduceStep: Int

    static let `default` = OverlapDetection(enabled: false, minIcons: 2, reduceStep: 1)

    enum CodingKeys: String, CodingKey {
        case enabled
        case minIcons = "min_icons"
        case reduceStep = "reduce_step"
    }

    func clamped() -> OverlapDetection {
        OverlapDetection(
            enabled: enabled,
            minIcons: min(max(minIcons, 2), 10),
            reduceStep: min(max(reduceStep, 1), 2)
        )
    }
}
