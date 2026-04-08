import Foundation

enum WindowAction: String, CaseIterable, Codable {
    case leftHalf
    case rightHalf
    case maximize
    case minimize
    case firstThird
    case centerThird
    case lastThird
    case firstTwoThirds
    case centerTwoThirds
    case lastTwoThirds

    var displayName: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .maximize: return "Maximize"
        case .firstThird: return "First Third"
        case .centerThird: return "Center Third"
        case .lastThird: return "Last Third"
        case .firstTwoThirds: return "First Two Thirds"
        case .centerTwoThirds: return "Center Two Thirds"
        case .lastTwoThirds: return "Last Two Thirds"
        case .minimize: return "Minimize"
        }
    }
}
