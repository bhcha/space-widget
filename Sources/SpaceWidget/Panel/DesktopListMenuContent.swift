import SwiftUI

struct DesktopListItem: Identifiable {
    let id: UInt64  // spaceID
    var spaceID: UInt64 { id }
    let ordinal: Int
    let label: String
    let isCurrent: Bool
}

struct DesktopListMenuContent: View {
    let items: [DesktopListItem]
    let currentSpaceID: UInt64
    let onSelect: (DesktopListItem) -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    DesktopListRow(
                        ordinal: item.ordinal,
                        label: item.label,
                        isCurrent: item.isCurrent,
                        action: { onSelect(item) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 360)
    }
}

private struct DesktopListRow: View {
    let ordinal: Int
    let label: String
    let isCurrent: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(isCurrent ? "✓" : " ")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(isCurrent ? 1.0 : 0.7))
                    .frame(width: 12)
                Text("\(ordinal)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(isCurrent ? 1.0 : 0.7))
                    .frame(width: 16, alignment: .trailing)
                Text(label.isEmpty ? " " : label)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(isCurrent ? 1.0 : 0.7))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.accentColor : Color.clear)
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
