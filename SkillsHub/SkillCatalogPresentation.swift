import Foundation

nonisolated enum Phase1SkillFilter: String, CaseIterable, Identifiable {
    case all
    case enabled
    case needsAttention
    case notEnabled

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .enabled: "Enabled"
        case .needsAttention: "Needs Attention"
        case .notEnabled: "Not Enabled"
        }
    }
}

nonisolated struct Phase1SkillPresentation: Identifiable, Hashable {
    var id: String
    var candidate: AvailableSkill?
    var managed: InstalledSkill?
    var source: SkillSource?
    var sourceName: String
    var isEnabled: Bool

    var relativeLocation: String {
        candidate?.skillPath ?? managed?.canonicalPathComponent ?? id
    }

    var name: String {
        let value = managed?.name ?? candidate?.name ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unnamed skill · \(relativeLocation)" : trimmed
    }

    var detail: String { managed?.description ?? candidate?.description ?? "" }
    var validationMessages: [String] {
        (managed?.validation.messages ?? candidate?.validation.messages ?? []).map(\.message)
    }
    var isManaged: Bool { managed != nil }
    var needsAttention: Bool {
        managed?.validation.status == .invalid
            || candidate?.checkStatus == .blocked
            || candidate?.checkStatus == .unreadable
    }
    var location: String { "\(sourceName) · \(relativeLocation)" }
}

nonisolated final class SkillCatalogPresentationService {
    func phase1Items(
        availableSkills: [AvailableSkill],
        installedSkills: [InstalledSkill],
        sources: [SkillSource],
        enablementIntents: [EnablementIntent]
    ) -> [Phase1SkillPresentation] {
        var managedByCandidate = installedSkills.reduce(into: [String: InstalledSkill]()) { result, skill in
            if let candidateID = skill.candidateID, result[candidateID] == nil {
                result[candidateID] = skill
            }
        }
        let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let enabledAssets = Set(enablementIntents.filter(\.isEnabled).map(\.assetID))
        var items = availableSkills.map { candidate in
            let managed = managedByCandidate.removeValue(forKey: candidate.candidateID)
            let source = sourceByID[candidate.sourceID]
            return Phase1SkillPresentation(
                id: candidate.candidateID,
                candidate: candidate,
                managed: managed,
                source: source,
                sourceName: source.map { sourceName(for: $0) } ?? "Unknown Source",
                isEnabled: managed.map { enabledAssets.contains($0.assetID) } ?? false
            )
        }
        items.append(contentsOf: installedSkills.filter { skill in
            !items.contains { $0.managed?.assetID == skill.assetID }
        }.map { skill in
            let source = skill.sourceID.flatMap { sourceByID[$0] } ?? sources
                .filter { source in
                    guard let path = source.localPath else { return false }
                    let installed = URL(fileURLWithPath: skill.installedPath, isDirectory: true).standardizedFileURL.path
                    let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
                    return installed == root || installed.hasPrefix(root + "/")
                }
                .max { ($0.localPath?.count ?? 0) < ($1.localPath?.count ?? 0) }
            return Phase1SkillPresentation(
                id: skill.assetID.uuidString,
                candidate: nil,
                managed: skill,
                source: source,
                sourceName: source.map { sourceName(for: $0) } ?? "Unknown Source",
                isEnabled: enabledAssets.contains(skill.assetID)
            )
        })
        return items.sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            let sourceOrder = $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName)
            if sourceOrder != .orderedSame { return sourceOrder == .orderedAscending }
            let pathOrder = $0.relativeLocation.localizedCaseInsensitiveCompare($1.relativeLocation)
            return pathOrder == .orderedAscending || (pathOrder == .orderedSame && $0.id < $1.id)
        }
    }

    func filteredPhase1Items(
        _ items: [Phase1SkillPresentation],
        query: String,
        filter: Phase1SkillFilter,
        sourceID: UUID? = nil
    ) -> [Phase1SkillPresentation] {
        let scoped = sourceID.map { id in items.filter { $0.source?.id == id } } ?? items
        let filtered = scoped.filter { item in
            switch filter {
            case .all: true
            case .enabled: item.isEnabled
            case .needsAttention: item.needsAttention
            case .notEnabled: !item.isEnabled
            }
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return filtered }
        return filtered.filter {
            $0.name.localizedStandardContains(trimmedQuery)
                || $0.detail.localizedStandardContains(trimmedQuery)
                || $0.sourceName.localizedStandardContains(trimmedQuery)
                || $0.relativeLocation.localizedStandardContains(trimmedQuery)
        }
    }

    func normalizedTag(_ rawValue: String, existingTags: [TagRecord] = []) -> TagRecord {
        let collapsed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let id = collapsed.lowercased().replacingOccurrences(of: " ", with: "-")
        if let existing = existingTags.first(where: { $0.id == id }) {
            return existing
        }
        let displayName = collapsed.split(separator: " ").map { word in
            word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
        return TagRecord(id: id, displayName: displayName)
    }

    func sourceName(for source: SkillSource) -> String {
        switch source.kind {
        case .githubRepository:
            if !source.name.isEmpty {
                return source.name
            }
            guard let urlString = source.urlString, let reference = try? GitHubRepositoryParser().parse(urlString) else {
                return source.urlString ?? "GitHub"
            }
            return reference.sourceName
        case .npmPackage:
            return source.name
        case .localDirectory:
            if !source.name.isEmpty {
                return source.name
            }
            return source.localPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Local"
        case .manualFilesystem:
            return "Local"
        }
    }
}
