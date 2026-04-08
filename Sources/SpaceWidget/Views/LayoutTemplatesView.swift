import SwiftUI

struct LayoutTemplatesView: View {
    @ObservedObject var store: LayoutTemplateStore
    @State private var selectedID: UUID?

    var body: some View {
        HSplitView {
            templateList
                .frame(minWidth: 160, maxWidth: 200)

            if let template = selectedTemplate {
                templateEditor(template)
                    .frame(minWidth: 340)
            } else {
                Text("Select a template")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minHeight: 420)
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

                Button("Restore Presets") {
                    store.restoreDefaults()
                    selectedID = store.templates.first?.id
                }
                .font(.caption)
                .buttonStyle(.borderless)
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
                        rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1),
                        assignedAppBundleID: nil
                    ))
                    store.updateTemplate(updated)
                }) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
            }

            ForEach(Array(template.zones.enumerated()), id: \.element.id) { index, zone in
                zoneRow(template: template, zone: zone, index: index)
            }
        }
    }

    private func zoneRow(template: LayoutTemplate, zone: LayoutZone, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Zone \(index + 1)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                if template.zones.count > 1 {
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
            }

            HStack(spacing: 8) {
                Text("X")
                    .frame(width: 14, alignment: .trailing)
                    .font(.caption)
                Slider(value: zoneRectBinding(template: template, zoneID: zone.id, keyPath: \.x), in: 0...max(0, 1 - zone.rect.width), step: 0.01)
                Text(String(format: "%.0f%%", zone.rect.x * 100))
                    .font(.caption.monospacedDigit())
                    .frame(width: 36)
            }

            HStack(spacing: 8) {
                Text("W")
                    .frame(width: 14, alignment: .trailing)
                    .font(.caption)
                Slider(value: zoneRectBinding(template: template, zoneID: zone.id, keyPath: \.width), in: 0.1...max(0.1, 1 - zone.rect.x), step: 0.01)
                Text(String(format: "%.0f%%", zone.rect.width * 100))
                    .font(.caption.monospacedDigit())
                    .frame(width: 36)
            }

            HStack {
                Text("App")
                    .frame(width: 28, alignment: .trailing)
                    .font(.caption)
                appPicker(template: template, zone: zone)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
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
            // Show saved bundle ID even if app is not running
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
        let newTemplate = LayoutTemplate(
            id: UUID(),
            name: "New Layout",
            shortcut: nil,
            zones: [
                LayoutZone(id: UUID(), rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1), assignedAppBundleID: nil),
                LayoutZone(id: UUID(), rect: NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1), assignedAppBundleID: nil),
            ]
        )
        store.addTemplate(newTemplate)
        selectedID = newTemplate.id
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        store.deleteTemplate(id: id)
        selectedID = store.templates.first?.id
    }

    private func zoneRectBinding(template: LayoutTemplate, zoneID: UUID, keyPath: WritableKeyPath<NormalizedRect, CGFloat>) -> Binding<CGFloat> {
        Binding(
            get: {
                guard let zone = template.zones.first(where: { $0.id == zoneID }) else { return 0 }
                return zone.rect[keyPath: keyPath]
            },
            set: { newValue in
                var updated = template
                if let idx = updated.zones.firstIndex(where: { $0.id == zoneID }) {
                    updated.zones[idx].rect[keyPath: keyPath] = newValue
                }
                store.updateTemplate(updated)
            }
        )
    }

    private func spaceAssignmentBinding(ordinal: Int) -> Binding<UUID?> {
        Binding(
            get: { store.spaceAssignments[ordinal] },
            set: { store.assignTemplate($0, toSpace: ordinal) }
        )
    }
}
