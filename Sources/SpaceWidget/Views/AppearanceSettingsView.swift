import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var settings: SpaceLabelSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance").font(.headline).padding(.bottom, 4)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Space Name Animation", isOn: $settings.isEnabled)
                        .toggleStyle(.switch)
                        .help("Show or hide the floating Space name when switching desktops.")
                    Text("Show the Space name for 2 seconds when switching desktops. It rises from the widget and returns when finished.")
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    HStack {
                        Text("Follows your Mac’s Reduce Motion setting.")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("Preview") { settings.preview() }
                            .buttonStyle(.bordered)
                            .disabled(!settings.isEnabled)
                    }
                }.padding(10)
            }
            Text("An auto-hidden widget appears briefly while the name is shown. Labels stay hidden in full screen.")
                .font(.caption).foregroundColor(.secondary)
            if let issue = settings.previewIssue {
                Text(issue).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }.padding(20)
    }
}
