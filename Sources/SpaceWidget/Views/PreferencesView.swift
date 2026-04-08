import SwiftUI

struct PreferencesView: View {
    @ObservedObject var configManager: ConfigManager
    @State private var shortcuts: [String: ShortcutBinding] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts")
                .font(.headline)
                .padding(.bottom, 4)

            ForEach(WindowAction.allCases, id: \.self) { action in
                HStack {
                    Toggle("", isOn: shortcutEnabled(for: action))
                        .toggleStyle(.checkbox)
                        .frame(width: 20)

                    Text(action.displayName)
                        .frame(width: 140, alignment: .leading)

                    ShortcutRecorderView(binding: shortcutBinding(for: action))

                    Button(action: { clearShortcut(for: action) }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear shortcut")
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    shortcuts = ConfigManager.defaultShortcuts
                    save()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            shortcuts = configManager.shortcuts
        }
    }

    private func shortcutEnabled(for action: WindowAction) -> Binding<Bool> {
        Binding(
            get: { shortcuts[action.rawValue]?.enabled ?? true },
            set: { newValue in
                shortcuts[action.rawValue]?.enabled = newValue
                save()
            }
        )
    }

    private func shortcutBinding(for action: WindowAction) -> Binding<ShortcutBinding> {
        Binding(
            get: {
                shortcuts[action.rawValue]
                    ?? ConfigManager.defaultShortcuts[action.rawValue]
                    ?? ShortcutBinding(keyCode: 0, modifiers: 0, enabled: false)
            },
            set: { newValue in
                shortcuts[action.rawValue] = newValue
                save()
            }
        )
    }

    private func clearShortcut(for action: WindowAction) {
        shortcuts[action.rawValue] = ShortcutBinding(keyCode: 0, modifiers: 0, enabled: false)
        save()
    }

    private func save() {
        configManager.saveShortcuts(shortcuts)
    }
}
