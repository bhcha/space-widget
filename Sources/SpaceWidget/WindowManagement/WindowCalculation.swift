import AppKit

struct CalculationParams {
    let windowFrame: CGRect
    let screenFrame: CGRect  // visibleFrame of the screen
}

struct CalculationResult {
    let rect: CGRect
    let action: WindowAction
}

protocol WindowCalculation {
    func calculate(_ params: CalculationParams, action: WindowAction) -> CalculationResult
}

// MARK: - Half Calculation

struct HalfCalculation: WindowCalculation {
    func calculate(_ params: CalculationParams, action: WindowAction) -> CalculationResult {
        let screen = params.screenFrame
        let rect: CGRect
        switch action {
        case .leftHalf:
            rect = CGRect(x: screen.minX, y: screen.minY,
                         width: screen.width / 2, height: screen.height)
        case .rightHalf:
            rect = CGRect(x: screen.midX, y: screen.minY,
                         width: screen.width / 2, height: screen.height)
        default:
            rect = params.windowFrame
        }
        return CalculationResult(rect: rect, action: action)
    }
}

// MARK: - Third Calculation

struct ThirdCalculation: WindowCalculation {
    func calculate(_ params: CalculationParams, action: WindowAction) -> CalculationResult {
        let screen = params.screenFrame
        let thirdWidth = screen.width / 3
        let rect: CGRect
        switch action {
        case .firstThird:
            rect = CGRect(x: screen.minX, y: screen.minY,
                         width: thirdWidth, height: screen.height)
        case .centerThird:
            rect = CGRect(x: screen.minX + thirdWidth, y: screen.minY,
                         width: thirdWidth, height: screen.height)
        case .lastThird:
            rect = CGRect(x: screen.minX + thirdWidth * 2, y: screen.minY,
                         width: thirdWidth, height: screen.height)
        default:
            rect = params.windowFrame
        }
        return CalculationResult(rect: rect, action: action)
    }
}

// MARK: - Two Thirds Calculation

struct TwoThirdsCalculation: WindowCalculation {
    func calculate(_ params: CalculationParams, action: WindowAction) -> CalculationResult {
        let screen = params.screenFrame
        let thirdWidth = screen.width / 3
        let twoThirdsWidth = thirdWidth * 2
        let rect: CGRect
        switch action {
        case .firstTwoThirds:
            rect = CGRect(x: screen.minX, y: screen.minY,
                         width: twoThirdsWidth, height: screen.height)
        case .centerTwoThirds:
            rect = CGRect(x: screen.minX + thirdWidth / 2, y: screen.minY,
                         width: twoThirdsWidth, height: screen.height)
        case .lastTwoThirds:
            rect = CGRect(x: screen.minX + thirdWidth, y: screen.minY,
                         width: twoThirdsWidth, height: screen.height)
        default:
            rect = params.windowFrame
        }
        return CalculationResult(rect: rect, action: action)
    }
}

// MARK: - Maximize Calculation

struct MaximizeCalculation: WindowCalculation {
    func calculate(_ params: CalculationParams, action: WindowAction) -> CalculationResult {
        return CalculationResult(rect: params.screenFrame, action: .maximize)
    }
}

// MARK: - Calculation Factory

enum WindowCalculationFactory {
    private static let half = HalfCalculation()
    private static let third = ThirdCalculation()
    private static let twoThirds = TwoThirdsCalculation()
    private static let maximize = MaximizeCalculation()

    static func calculation(for action: WindowAction) -> WindowCalculation {
        switch action {
        case .leftHalf, .rightHalf: return half
        case .firstThird, .centerThird, .lastThird: return third
        case .firstTwoThirds, .centerTwoThirds, .lastTwoThirds: return twoThirds
        case .maximize: return maximize
        case .minimize: return maximize // unreachable — handled in WindowSnapManager
        }
    }
}
