import SwiftUI

struct WindowActionIcon: View {
    let action: WindowAction

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 1
            let rect = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)

            // Draw outer border
            let borderPath = Path(roundedRect: rect, cornerRadius: 1)
            context.stroke(borderPath, with: .color(.primary.opacity(0.5)), lineWidth: 0.75)

            // Draw filled zone
            let zoneRect = zoneRect(in: rect)
            let zonePath = Path(roundedRect: zoneRect, cornerRadius: 0.5)
            context.fill(zonePath, with: .color(.accentColor.opacity(0.6)))
        }
        .frame(width: 16, height: 12)
    }

    private func zoneRect(in bounds: CGRect) -> CGRect {
        let x = bounds.minX
        let y = bounds.minY
        let w = bounds.width
        let h = bounds.height
        let third = w / 3

        switch action {
        case .leftHalf:
            return CGRect(x: x, y: y, width: w / 2, height: h)
        case .rightHalf:
            return CGRect(x: x + w / 2, y: y, width: w / 2, height: h)
        case .maximize:
            return bounds
        case .firstThird:
            return CGRect(x: x, y: y, width: third, height: h)
        case .centerThird:
            return CGRect(x: x + third, y: y, width: third, height: h)
        case .lastThird:
            return CGRect(x: x + third * 2, y: y, width: third, height: h)
        case .firstTwoThirds:
            return CGRect(x: x, y: y, width: third * 2, height: h)
        case .centerTwoThirds:
            return CGRect(x: x + third / 2, y: y, width: third * 2, height: h)
        case .lastTwoThirds:
            return CGRect(x: x + third, y: y, width: third * 2, height: h)
        case .minimize:
            // Not used in zones, but provide a fallback
            return CGRect(x: x + w * 0.25, y: y + h * 0.25, width: w * 0.5, height: h * 0.5)
        }
    }
}
