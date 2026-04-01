import SwiftUI
import AppKit

struct SpaceBarView: View {
    let spaceNumber: String
    let spaceLabel: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
            barContent
                .padding(.leading, 8)
                .padding(.bottom, 6)
        }
        .edgesIgnoringSafeArea(.all)
    }

    private var barContent: some View {
        HStack(spacing: 15) {
            Text(spaceNumber)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 32, alignment: .center)

            Text(spaceLabel)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)
                .frame(width: 74, alignment: .leading)

            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 1.5, height: 18)

            HStack(spacing: 9) {
                ForEach(dummyIcons, id: \.self) { icon in
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 39, height: 39)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 45)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
    }

    private var dummyIcons: [NSImage] {
        let bundleIDs = [
            "com.apple.finder",
            "com.apple.Safari",
            "com.apple.Terminal",
            "com.google.Chrome"
        ]
        return bundleIDs.compactMap { bundleID in
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return nil
        }
    }
}
