import Foundation
import Combine

final class LayoutTemplateStore: ObservableObject {
    @Published private(set) var templates: [LayoutTemplate] = []
    @Published private(set) var spaceAssignments: [Int: UUID] = [:]  // ordinal → template ID
    @Published var autoApplyEnabled: Bool = false

    private var templatesURL: URL { ConfigManager.configDir.appendingPathComponent("templates.json") }
    private var spaceAssignmentsURL: URL { ConfigManager.configDir.appendingPathComponent("space_assignments.json") }

    // MARK: - Default Presets

    static let defaultTemplates: [LayoutTemplate] = [
        LayoutTemplate(
            id: UUID(),
            name: "Template 1",
            shortcut: nil,
            zones: []
        ),
    ]

    // MARK: - Load

    func load() {
        templates = loadTemplates()
        let assignments = loadSpaceAssignments()
        spaceAssignments = assignments.assignments
        autoApplyEnabled = assignments.autoApplyEnabled
    }

    private func loadTemplates() -> [LayoutTemplate] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: templatesURL.path),
              let data = try? Data(contentsOf: templatesURL),
              let loaded = try? JSONDecoder().decode([LayoutTemplate].self, from: data)
        else {
            let defaults = Self.defaultTemplates
            saveTemplates(defaults)
            return defaults
        }
        return loaded
    }

    private func loadSpaceAssignments() -> SpaceAssignmentsFile {
        guard let data = try? Data(contentsOf: spaceAssignmentsURL),
              let loaded = try? JSONDecoder().decode(SpaceAssignmentsFile.self, from: data)
        else {
            return SpaceAssignmentsFile(assignments: [:], autoApplyEnabled: false)
        }
        return loaded
    }

    // MARK: - Save

    private func saveTemplates(_ list: [LayoutTemplate]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(list) else { return }
        try? data.write(to: templatesURL, options: .atomic)
    }

    private func saveSpaceAssignments() {
        let file = SpaceAssignmentsFile(assignments: spaceAssignments, autoApplyEnabled: autoApplyEnabled)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: spaceAssignmentsURL, options: .atomic)
    }

    // MARK: - CRUD

    func addTemplate(_ template: LayoutTemplate) {
        templates.append(template)
        saveTemplates(templates)
    }

    func updateTemplate(_ template: LayoutTemplate) {
        guard let idx = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[idx] = template
        saveTemplates(templates)
    }

    func restoreDefaults() {
        templates = Self.defaultTemplates
        // Clear stale space assignments pointing at removed template IDs
        let validIDs = Set(templates.map(\.id))
        spaceAssignments = spaceAssignments.filter { validIDs.contains($0.value) }
        saveTemplates(templates)
        saveSpaceAssignments()
    }

    func deleteTemplate(id: UUID) {
        templates.removeAll { $0.id == id }
        // Clean up space assignments referencing deleted template
        spaceAssignments = spaceAssignments.filter { $0.value != id }
        saveTemplates(templates)
        saveSpaceAssignments()
    }

    // MARK: - Space Assignments

    func assignTemplate(_ templateID: UUID?, toSpace ordinal: Int) {
        if let templateID {
            spaceAssignments[ordinal] = templateID
        } else {
            spaceAssignments.removeValue(forKey: ordinal)
        }
        saveSpaceAssignments()
    }

    func templateForSpace(_ ordinal: Int) -> LayoutTemplate? {
        guard let templateID = spaceAssignments[ordinal] else { return nil }
        return templates.first { $0.id == templateID }
    }

    func setAutoApplyEnabled(_ enabled: Bool) {
        autoApplyEnabled = enabled
        saveSpaceAssignments()
    }
}

// MARK: - Persistence Model

private struct SpaceAssignmentsFile: Codable {
    var assignments: [Int: UUID]
    var autoApplyEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case assignments
        case autoApplyEnabled
    }

    init(assignments: [Int: UUID], autoApplyEnabled: Bool) {
        self.assignments = assignments
        self.autoApplyEnabled = autoApplyEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoApplyEnabled = try container.decode(Bool.self, forKey: .autoApplyEnabled)
        // JSON keys are strings, decode and convert to Int
        let stringKeyed = try container.decode([String: UUID].self, forKey: .assignments)
        assignments = Dictionary(uniqueKeysWithValues: stringKeyed.compactMap { k, v in
            guard let i = Int(k) else { return nil }
            return (i, v)
        })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(autoApplyEnabled, forKey: .autoApplyEnabled)
        let stringKeyed = Dictionary(uniqueKeysWithValues: assignments.map { ("\($0.key)", $0.value) })
        try container.encode(stringKeyed, forKey: .assignments)
    }
}
