import SwiftUI

struct LayoutTemplatesView: View {
    @ObservedObject var store: LayoutTemplateStore
    @State private var selectedID: UUID?

    // WindowAction cases available for zones (exclude minimize)
    private var availableActions: [WindowAction] {
        WindowAction.allCases.filter { $0 != .minimize }
    }

    var body: some View {
        HSplitView {
            templateList
                .frame(minWidth: 160, maxWidth: 200)

            if let template = selectedTemplate {
                templateEditor(template)
                    .frame(minWidth: 380)
            } else {
                Text("Select a template")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minHeight: 600)
        .onAppear {
            if selectedID == nil {
                selectedID = store.templates.first?.id
            }
        }
    }

    // MARK: - Template List

    private var templateList: some View {
        VStack(spacing: 0) {
            List(store.templates, selection: $selectedID) { template in
                Text(template.name)
                    .tag(template.id)
            }

            Divider()

            HStack {
                Button(action: addTemplate) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)

                Button(action: deleteSelected) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedID == nil)

                Spacer()
            }
            .padding(6)
        }
    }

    // MARK: - Template Editor

    private func templateEditor(_ template: LayoutTemplate) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                nameSection(template)
                shortcutSection(template)
                zonesSection(template)
                Divider()
                spaceAssignmentSection
            }
            .padding(16)
        }
    }

    private func nameSection(_ template: LayoutTemplate) -> some View {
        HStack {
            Text("Name")
                .frame(width: 60, alignment: .trailing)
            TextField("Template name", text: Binding(
                get: { template.name },
                set: { newName in
                    var updated = template
                    updated.name = newName
                    store.updateTemplate(updated)
                }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }

    private func shortcutSection(_ template: LayoutTemplate) -> some View {
        HStack {
            Text("Shortcut")
                .frame(width: 60, alignment: .trailing)

            ShortcutRecorderView(binding: Binding(
                get: {
                    template.shortcut ?? ShortcutBinding(keyCode: 0, modifiers: 0, enabled: true)
                },
                set: { newBinding in
                    var updated = template
                    if newBinding.keyCode == 0 && newBinding.modifiers == 0 {
                        updated.shortcut = nil
                    } else {
                        updated.shortcut = newBinding
                    }
                    store.updateTemplate(updated)
                }
            ))

            Button(action: {
                var updated = template
                updated.shortcut = nil
                store.updateTemplate(updated)
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear shortcut")
        }
    }

    private func zonesSection(_ template: LayoutTemplate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Zones")
                    .font(.headline)
                Spacer()
                Button(action: {
                    var updated = template
                    updated.zones.append(LayoutZone(
                        id: UUID(),
                        action: .leftHalf,
                        assignedAppBundleID: nil
                    ))
                    store.updateTemplate(updated)
                }) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
            }

            if template.zones.isEmpty {
                Text("No zones. Click + to add a zone.")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .padding(.vertical, 8)
            }

            ForEach(Array(template.zones.enumerated()), id: \.element.id) { index, zone in
                zoneRow(template: template, zone: zone, index: index)
            }
        }
    }

    private func zoneRow(template: LayoutTemplate, zone: LayoutZone, index: Int) -> some View {
        HStack(spacing: 8) {
            // Zone number
            Text("\(index + 1)")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 16)

            // WindowAction picker with icon
            Picker("", selection: Binding(
                get: { zone.action },
                set: { newAction in
                    var updated = template
                    if let idx = updated.zones.firstIndex(where: { $0.id == zone.id }) {
                        updated.zones[idx].action = newAction
                    }
                    store.updateTemplate(updated)
                }
            )) {
                ForEach(availableActions, id: \.self) { action in
                    Label {
                        Text(action.displayName)
                    } icon: {
                        WindowActionIcon(action: action)
                    }
                    .tag(action)
                }
            }
            .labelsHidden()
            .frame(width: 160)

            // App picker
            appPicker(template: template, zone: zone)

            // Delete button
            Button(action: {
                var updated = template
                updated.zones.removeAll { $0.id == zone.id }
                store.updateTemplate(updated)
            }) {
                Image(systemName: "minus.circle")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.06)))
    }

    private func appPicker(template: LayoutTemplate, zone: LayoutZone) -> some View {
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        let runningBundleIDs = Set(runningApps.compactMap(\.bundleIdentifier))
        let savedBundleID = zone.assignedAppBundleID

        return Picker("", selection: Binding(
            get: { zone.assignedAppBundleID ?? "" },
            set: { newValue in
                var updated = template
                if let idx = updated.zones.firstIndex(where: { $0.id == zone.id }) {
                    updated.zones[idx].assignedAppBundleID = newValue.isEmpty ? nil : newValue
                }
                store.updateTemplate(updated)
            }
        )) {
            Text("None").tag("")
            if let saved = savedBundleID, !saved.isEmpty, !runningBundleIDs.contains(saved) {
                Text("\(saved) (not running)")
                    .tag(saved)
            }
            ForEach(runningApps, id: \.bundleIdentifier) { app in
                Text(app.localizedName ?? app.bundleIdentifier ?? "Unknown")
                    .tag(app.bundleIdentifier ?? "")
            }
        }
        .labelsHidden()
    }

    // MARK: - Space Assignments

    private var spaceAssignmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Space Assignments")
                .font(.headline)

            ForEach(1...9, id: \.self) { ordinal in
                HStack {
                    Text("Space \(ordinal)")
                        .frame(width: 70, alignment: .trailing)
                    Picker("", selection: spaceAssignmentBinding(ordinal: ordinal)) {
                        Text("None").tag(UUID?.none as UUID?)
                        ForEach(store.templates) { template in
                            Text(template.name).tag(Optional(template.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            Toggle("Auto-apply on Space Switch", isOn: Binding(
                get: { store.autoApplyEnabled },
                set: { store.setAutoApplyEnabled($0) }
            ))
            .padding(.top, 4)
        }
    }

    // MARK: - Helpers

    private var selectedTemplate: LayoutTemplate? {
        guard let id = selectedID else { return nil }
        return store.templates.first { $0.id == id }
    }

    private func addTemplate() {
        let count = store.templates.count + 1
        let newTemplate = LayoutTemplate(
            id: UUID(),
            name: "Template \(count)",
            shortcut: nil,
            zones: []
        )
        store.addTemplate(newTemplate)
        selectedID = newTemplate.id
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        store.deleteTemplate(id: id)
        selectedID = store.templates.first?.id
    }

    private func spaceAssignmentBinding(ordinal: Int) -> Binding<UUID?> {
        Binding(
            get: { store.spaceAssignments[ordinal] },
            set: { store.assignTemplate($0, toSpace: ordinal) }
        )
    }
}
