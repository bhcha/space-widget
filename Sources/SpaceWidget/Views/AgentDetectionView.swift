import SwiftUI

/// Scanning and rendering are read-only. Only explicit button actions mutate hooks.
struct AgentDetectionView: View {
    @StateObject private var model: AgentDetectionModel
    @StateObject private var hooks: HookInstallationModel
    @ObservedObject private var notifications: AgentNotificationModel
    @ObservedObject private var shortcut: AgentToastShortcut
    @State private var showingTrustHelp = false

    init(model: AgentDetectionModel? = nil,
         hooks: HookInstallationModel? = nil,
         notifications: AgentNotificationModel? = nil,
         shortcut: AgentToastShortcut? = nil) {
        _model = StateObject(wrappedValue: model ?? AgentDetectionModel())
        _hooks = StateObject(wrappedValue: hooks ?? HookInstallationModel())
        self.notifications = notifications ?? .shared
        self.shortcut = shortcut ?? .shared
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI Agents")
                    .font(.headline)
                    .padding(.bottom, 4)

                Text("Get notified when an agent responds and return to the Space where it started.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text(model.isScanning ? "Checking installed agents..." : "\(model.results.filter { !$0.runtimes.isEmpty }.count) agents found")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    if model.isScanning { ProgressView().controlSize(.small) }
                    Button("Rescan") { Task { await rescan() } }
                        .buttonStyle(.bordered)
                        .disabled(model.isScanning || hooks.busy)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                            if index > 0 { Divider() }
                            AgentSettingsCard(result: result, state: hooks.states[result.agent] ?? .installable,
                                busy: hooks.busy || model.isScanning, backup: hooks.backups[result.agent],
                                install: { Task { await hooks.install(result) } },
                                uninstall: { Task { await hooks.uninstall(result) } },
                                trustHelp: { showingTrustHelp = true },
                                preview: { notifications.testNotification(agent: result.agent) },
                                previewEnabled: notifications.notificationsEnabled)
                        }
                        if model.results.isEmpty {
                            Text("Checking installed agents...")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(8)
                }

                Text("Install or remove SpaceWidget hooks without changing your other hooks.")
                    .font(.caption).foregroundColor(.secondary)

                Divider()

                Text("Notifications").font(.headline)
                Toggle("Show response notifications", isOn: $notifications.notificationsEnabled)
                    .toggleStyle(.checkbox)
                Toggle("Play notification sound", isOn: $notifications.soundEnabled)
                    .toggleStyle(.checkbox)
                    .disabled(!notifications.notificationsEnabled)

                Text("Click a notification or use the shortcut to return to the task's Space.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label("Some terminals cannot report which window started a task. In Ghostty, when its windows are on more than one Space, the notification shows Unknown Space and cannot return to it.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Toggle("Enable notification shortcut", isOn: $shortcut.binding.enabled)
                        .labelsHidden().toggleStyle(.checkbox).frame(width: 20)
                    Image(systemName: "keyboard").frame(width: 20)
                    Text("Go to Space")
                        .frame(width: 140, alignment: .leading)
                    ShortcutRecorderView(binding: $shortcut.binding, onRecordingChanged: shortcut.setRecording)
                    Button {
                        shortcut.binding = ShortcutBinding(keyCode: 0, modifiers: 0, enabled: false)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear shortcut")
                }
                Text("Default: Control + Option + G. Active only while a notification is visible.")
                    .font(.caption).foregroundColor(.secondary)
                if let issue = shortcut.issue {
                    Text(issue).font(.caption).foregroundColor(.red)
                }

                if notifications.pendingCount > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(notifications.pendingCount) notifications from an earlier run are waiting.")
                            .font(.caption).foregroundColor(.secondary)
                        HStack {
                            Button("Show Pending") { Task { await notifications.resolvePending(show: true) } }
                            Button("Discard Pending") { Task { await notifications.resolvePending(show: false) } }
                        }.buttonStyle(.bordered)
                    }
                }
                if let issue = notifications.deliveryIssue {
                    Text(issue).font(.caption).foregroundColor(.secondary)
                }

                Divider()

                HStack {
                    Button("Preview Notification") { notifications.testNotification() }
                        .disabled(!notifications.notificationsEnabled)
                    Spacer()
                    Button("Restore Default Shortcut") { shortcut.binding = AgentToastShortcut.defaultBinding }
                }.buttonStyle(.bordered)

                DisclosureGroup("Support & Details") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CLI and desktop installations are detected separately. Installing an app does not confirm that its hooks are working.")
                        Text("Claude hooks apply to local Code sessions, not regular Chat. Codex hooks must be reviewed and approved in Codex. Project settings or policies may prevent hooks from running.")
                        Text("The task's Space is detected when the request starts. Navigation is available when that Space can be identified. Preview does not verify a live hook connection.")
                    }
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                }.font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { if model.results.isEmpty { await rescan() } }
        .sheet(isPresented: $showingTrustHelp) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Approve Hooks in Codex").font(.headline).padding(.bottom, 4)
                Text("1. Open /hooks in your Codex session.\n2. Review and approve SpaceWidget's SessionStart, UserPromptSubmit, and Stop hooks.\n3. Finish a response in a new local session to check notification delivery.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("SpaceWidget cannot read Codex's approval status. The approval reminder remains after approval; a real notification confirms delivery.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Close") { showingTrustHelp = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Rescan") { showingTrustHelp = false; Task { await rescan() } }
                        .disabled(hooks.busy || model.isScanning)
                }.buttonStyle(.bordered)
            }.padding(20).frame(width: 420)
        }
    }

    private func rescan() async { await model.rescan(); hooks.refresh(model.results) }
}

/// Shared by rendering and tests so action availability cannot overstate readiness.
struct AgentCardPresentation {
    let result: AgentDetection
    let state: HookInstallationState
    let busy: Bool

    var canInstall: Bool { !busy && result.allowsHookSetup }
    var offersInstall: Bool {
        switch state {
        case .installable, .updateAvailable, .uninstalled, .failure: return true
        default: return false
        }
    }
    var offersUninstall: Bool {
        switch state {
        case .pendingTrust, .awaitingExecution, .connected, .updateAvailable, .failure: return true
        default: return false
        }
    }
    var installTitle: String {
        if state == .updateAvailable { return "Update Hooks" }
        if case .failure = state { return "Retry" }
        return "Install Hooks"
    }
    var status: String {
        if case .installable = state { return result.readiness }
        return state.label
    }
    var tint: Color {
        switch state {
        case .failure: return .red
        case .pendingTrust, .awaitingExecution: return .orange
        case .connected: return .green
        default: return .secondary
        }
    }
}

struct AgentSettingsCard: View {
    let result: AgentDetection
    let state: HookInstallationState
    let busy: Bool
    var backup: URL?
    let install: () -> Void
    let uninstall: () -> Void
    let trustHelp: () -> Void
    let preview: () -> Void
    var previewEnabled = true

    private var presentation: AgentCardPresentation { .init(result: result, state: state, busy: busy) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: result.agent == .codex ? "terminal" : "asterisk")
                    .frame(width: 20, height: 20)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(result.agent.name).fontWeight(.medium)
                        Text(result.agent.provider).font(.caption).foregroundColor(.secondary)
                    }
                    Text(result.runtimes.isEmpty ? "Not found on this Mac" : result.runtimes.map { "\($0.scope.rawValue) · \($0.version ?? "Unknown version")" }.joined(separator: " / "))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    if presentation.offersInstall {
                        Button(presentation.installTitle, action: install).disabled(!presentation.canInstall)
                    }
                    if state == .installing { ProgressView("Installing...").controlSize(.small) }
                    if state == .connected {
                        Button("Test Notification", action: preview).disabled(!previewEnabled)
                    }
                    if state == .pendingTrust { Button("Approval Help", action: trustHelp) }
                    if presentation.offersUninstall { Button("Remove Hooks", action: uninstall).disabled(busy) }
                }.buttonStyle(.bordered)
            }
            Text(presentation.status).font(.caption).foregroundColor(presentation.tint)
                .fixedSize(horizontal: false, vertical: true)
            if presentation.offersInstall && result.runtimes.contains(where: { $0.scope == .desktop })
                && !result.runtimes.contains(where: { $0.capability == .supported }) {
                Text(result.agent == .claude
                     ? "For local Code sessions only. Connection is confirmed after the first hook runs."
                     : "For local Codex sessions. Approve the hooks in Codex, then check notification delivery.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state == .installing {
                Text("Saving hooks. Installation continues if you close this window.")
                    .font(.caption).foregroundColor(.secondary)
            }
            if state == .awaitingExecution {
                Text("Finish a response in a new local Code session, then rescan.")
                    .font(.caption).foregroundColor(.secondary)
            }
            DisclosureGroup("Configuration & Support") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(result.runtimes) { runtime in
                        Text("\(runtime.scope.rawValue) · \(runtime.capability.label)")
                        Text(runtime.location.path).textSelection(.enabled)
                    }
                    Text("Configuration: \(result.configurationDirectory.path)").textSelection(.enabled)
                    Text("Detected from SpaceWidget's environment. Terminal, app, and project settings may differ.")
                    ForEach(result.issues, id: \.self) { Text($0).foregroundColor(.red) }
                    if let backup { Text("Backup: \(backup.path)").textSelection(.enabled) }
                }
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }.font(.caption)
        }.padding(.vertical, 4)
    }
}
