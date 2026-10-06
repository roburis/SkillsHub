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
    var sourceName: LocalizedMessage
    var isEnabled: Bool
    var identityConflict: Bool = false

    var relativeLocation: String {
        candidate?.skillPath ?? managed?.canonicalPathComponent ?? id
    }

    var name: String {
        let value = managed?.name ?? candidate?.name ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unnamed skill · \(relativeLocation)" : trimmed
    }

    var detail: String { managed?.description ?? candidate?.description ?? "" }
    var sourceNameText: String { SkillsHubLocalization().localized(sourceName, language: .english) }
    var validationMessages: [LocalizedMessage] {
        (managed?.validation.messages ?? candidate?.validation.messages ?? []).map(\.presentationMessage)
            + (identityConflict ? ["Skill identity conflicts with its source location. Re-check before changing relationships."] : [])
    }
    var needsAttention: Bool {
        identityConflict || managed?.validation.status == .invalid
            || candidate?.checkStatus == .blocked
            || candidate?.checkStatus == .unreadable
    }
    var contentDirectoryPath: String? {
        if let managed { return managed.installedPath }
        guard let candidate, let base = source?.localPath, base.hasPrefix("/"), !base.contains("\0"),
              !candidate.skillPath.isEmpty, !candidate.skillPath.hasPrefix("/"), !candidate.skillPath.contains("\0") else { return nil }
        let sourceURL = URL(fileURLWithPath: base).standardized
        let directory = sourceURL.appendingPathComponent(candidate.skillPath).standardized
        let prefix = sourceURL.path == "/" ? "/" : sourceURL.path + "/"
        guard directory.path == sourceURL.path || directory.path.hasPrefix(prefix) else { return nil }
        return directory.path
    }
}

nonisolated final class SkillCatalogPresentationService {
    static func relativeDirectoryPath(_ directoryPath: String?, relativeTo basePath: String?) -> String? {
        guard let directoryPath, let basePath, directoryPath.hasPrefix("/"), basePath.hasPrefix("/"),
              !directoryPath.contains("\0"), !basePath.contains("\0") else { return nil }
        func addressPath(_ path: String) -> String {
            let path = URL(fileURLWithPath: path).standardized.path
            // Presentation only: keep macOS directory aliases consistent even when the entry is missing.
            if ["/private/tmp", "/private/var"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                return String(path.dropFirst("/private".count))
            }
            return path
        }
        let directory = addressPath(directoryPath)
        let base = addressPath(basePath)
        let prefix = base == "/" ? "/" : base + "/"
        guard directory == base || directory.hasPrefix(prefix) else { return nil }
        return directory == base ? "" : String(directory.dropFirst(prefix.count))
    }

    static func entryAddress(
        directoryPath: String?, relativeTo basePath: String?, nodeKind: TargetNodeKind?,
        entryVerified: Bool, entryUnavailable: Bool = false
    ) -> (path: String?, status: LocalizedMessage?) {
        guard nodeKind != .regularFile, nodeKind != .other,
              let relative = relativeDirectoryPath(directoryPath, relativeTo: basePath) else {
            return (nil, "Skill address could not be verified.")
        }
        let path = (relative.isEmpty ? "" : relative + "/") + "SKILL.md"
        if nodeKind == .vacant || nodeKind == .brokenSymbolicLink {
            return (path, "Recorded address; the Skill entry is missing.")
        }
        if nodeKind == nil || nodeKind == .unreadable {
            return (path, "Recorded address; SKILL.md has not been verified.")
        }
        if entryUnavailable { return (path, "SKILL.md is missing or unreadable.") }
        return (path, entryVerified ? nil : "Recorded address; SKILL.md has not been verified.")
    }

    func phase1Items(
        availableSkills: [AvailableSkill],
        installedSkills: [InstalledSkill],
        sources: [SkillSource],
        enablementIntents: [EnablementIntent],
        rootURL: URL? = nil
    ) -> [Phase1SkillPresentation] {
        let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let enabledAssets = Set(enablementIntents.filter(\.isEnabled).map(\.assetID))
        let installedByPath = Dictionary(grouping: installedSkills.indices) {
            URL(fileURLWithPath: installedSkills[$0].installedPath).standardizedFileURL.path
        }
        var installedByCandidate: [String: [Int]] = [:]
        for index in installedSkills.indices {
            if let candidateID = installedSkills[index].candidateID {
                installedByCandidate[candidateID, default: []].append(index)
            }
        }
        var pairedAssets: Set<UUID> = []
        var conflictingAssets: Set<UUID> = []
        var items = availableSkills.map { candidate in
            let source = sourceByID[candidate.sourceID]
            let path = source?.localPath.map {
                URL(fileURLWithPath: $0).appendingPathComponent(candidate.skillPath).standardizedFileURL.path
            }
            let locationMatches = (path.flatMap { installedByPath[$0] } ?? []).filter {
                Self.matchesLocation(installedSkills[$0], candidate: candidate, source: source)
            }
            let matchingIndices = Set(locationMatches).union(installedByCandidate[candidate.candidateID] ?? [])
            let matches = matchingIndices.sorted().map { installedSkills[$0] }
            let managed = matches.count == 1 && Self.matchesLocation(matches[0], candidate: candidate, source: source)
                && (matches[0].candidateID == nil || matches[0].candidateID == candidate.candidateID)
                ? matches[0] : nil
            let conflict = !matches.isEmpty && managed == nil
            if let managed { pairedAssets.insert(managed.assetID) }
            if conflict { conflictingAssets.formUnion(matches.map(\.assetID)) }
            return Phase1SkillPresentation(
                id: managed?.assetID.uuidString ?? candidate.candidateID,
                candidate: candidate,
                managed: managed,
                source: source,
                sourceName: source.map { sourceName(for: $0, relativeTo: rootURL) } ?? "Unknown Source",
                isEnabled: managed.map { enabledAssets.contains($0.assetID) } ?? false,
                identityConflict: conflict
            )
        }
        items.append(contentsOf: installedSkills.filter { skill in
            !pairedAssets.contains(skill.assetID)
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
                sourceName: source.map { sourceName(for: $0, relativeTo: rootURL) } ?? "Unknown Source",
                isEnabled: enabledAssets.contains(skill.assetID),
                identityConflict: conflictingAssets.contains(skill.assetID)
            )
        })
        return items.sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            let sourceOrder = $0.sourceNameText.localizedCaseInsensitiveCompare($1.sourceNameText)
            if sourceOrder != .orderedSame { return sourceOrder == .orderedAscending }
            let pathOrder = $0.relativeLocation.localizedCaseInsensitiveCompare($1.relativeLocation)
            return pathOrder == .orderedAscending || (pathOrder == .orderedSame && $0.id < $1.id)
        }
    }

    static func matchesLocation(_ skill: InstalledSkill, candidate: AvailableSkill, source: SkillSource?) -> Bool {
        guard let source, candidate.sourceID == source.id, let path = source.localPath,
              skill.sourceID == source.id || (skill.sourceID == nil && (skill.sourceKind == .manualFilesystem || skill.sourceKind == .localDirectory)) else { return false }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let location = candidate.skillPath == "." ? root : root.appendingPathComponent(candidate.skillPath).standardizedFileURL
        guard location.path == root.path || location.path.hasPrefix(root.path + "/") else { return false }
        return URL(fileURLWithPath: skill.installedPath).standardizedFileURL.path == location.path
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
                || $0.sourceNameText.localizedStandardContains(trimmedQuery)
                || $0.relativeLocation.localizedStandardContains(trimmedQuery)
        }
    }

    func sourceName(for source: SkillSource, relativeTo rootURL: URL? = nil) -> LocalizedMessage {
        switch source.kind {
        case .githubRepository:
            if !source.name.isEmpty {
                return .verbatim(source.name)
            }
            guard let urlString = source.urlString, let reference = try? GitHubRepositoryParser().parse(urlString) else {
                return .verbatim(source.urlString ?? "GitHub")
            }
            return .verbatim(reference.sourceName)
        case .npmPackage:
            return .verbatim(source.name)
        case .localDirectory, .manualFilesystem:
            guard let relative = Self.relativeDirectoryPath(source.localPath, relativeTo: rootURL?.path) else { return "Unknown Source" }
            let components = relative.split(separator: "/")
            guard components.count >= 2, components[0] == "local" else { return "Unknown Source" }
            return LocalizedMessage("Local/%@", arguments: [String(components[1])])
        }
    }
}
