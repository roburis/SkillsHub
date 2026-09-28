import Foundation

nonisolated enum InstallableEntryKind: String, Codable, Hashable {
    case skill
    case collection
    case composite
}

nonisolated struct InstallableEntry: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var path: String
    var kind: InstallableEntryKind
    var validation: SkillValidationResult
    var children: [InstallableEntry]

    init(
        id: String,
        name: String,
        path: String,
        kind: InstallableEntryKind,
        validation: SkillValidationResult,
        children: [InstallableEntry] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.validation = validation
        self.children = children
    }

    var warningReason: String? {
        validation.messages.first?.message ?? validation.risks.first?.detail
    }
}
