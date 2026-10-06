import Foundation
import Yams

nonisolated extension ValidationMessage {
    var presentationMessage: LocalizedMessage {
        switch id {
        case "missing-skill-file": "A readable SKILL.md file within this Skill is required."
        case "unreadable-skill-file": "SKILL.md could not be read as UTF-8."
        case "content-changed": "SKILL.md changed after its manifest was observed."
        case "empty-skill-id": "Normalized skill id is empty."
        case "skill-id-conflict": "Skill id conflicts with an existing skill."
        case "name-directory-mismatch": "Frontmatter name does not match directory name."
        case "description-length": "Description length should be reviewed."
        case "missing-source-metadata": "Source metadata is missing."
        case "frontmatter-syntax": "YAML frontmatter has invalid syntax."
        case "frontmatter-format": "YAML frontmatter must be one mapping with unique, non-empty string name and description fields."
        case "frontmatter-capability": "YAML frontmatter could not be parsed within the supported parser capability."
        case "frontmatter-budget": "YAML frontmatter exceeds the bounded parsing limits."
        default: LocalizedMessage("Check detail (original): %@", arguments: [message])
        }
    }
}

nonisolated struct SkillFrontmatter: Equatable {
    var name: String
    var description: String
}

nonisolated enum SkillFrontmatterErrorCategory: String, Equatable {
    case syntax
    case format
    case capability
    case budget
}

nonisolated enum SkillFrontmatterError: Error, Equatable {
    case missingDelimiter
    case invalidSyntax
    case duplicateField(String)
    case topLevelMappingRequired
    case missingRequiredField(String)
    case invalidRequiredFieldType(String)
    case parserCapabilityExceeded
    case inputBudgetExceeded
    case depthBudgetExceeded
    case nodeBudgetExceeded
    case aliasBudgetExceeded

    var category: SkillFrontmatterErrorCategory {
        switch self {
        case .invalidSyntax:
            .syntax
        case .missingDelimiter, .duplicateField, .topLevelMappingRequired,
             .missingRequiredField, .invalidRequiredFieldType:
            .format
        case .parserCapabilityExceeded:
            .capability
        case .inputBudgetExceeded, .depthBudgetExceeded, .nodeBudgetExceeded, .aliasBudgetExceeded:
            .budget
        }
    }
}

nonisolated struct SkillFrontmatterBudget: Equatable, Sendable {
    var maxInputBytes = 64 * 1024
    var maxDepth = 32
    var maxNodes = 2_048
    var maxAliases = 64
}

nonisolated struct SkillFrontmatterParser: Sendable {
    var budget = SkillFrontmatterBudget()

    func parse(_ text: String) throws -> SkillFrontmatter {
        let yaml = try frontmatterYAML(in: text)
        guard yaml.utf8.count <= budget.maxInputBytes else {
            throw SkillFrontmatterError.inputBudgetExceeded
        }

        do {
            let parser = try Parser(yaml: yaml)
            guard let root = try parser.singleRoot() else {
                throw SkillFrontmatterError.topLevelMappingRequired
            }
            try checkBudget(root)
            guard case .mapping(let mapping) = root else {
                throw SkillFrontmatterError.topLevelMappingRequired
            }
            return SkillFrontmatter(
                name: try requiredString("name", in: mapping),
                description: try requiredString("description", in: mapping)
            )
        } catch let error as SkillFrontmatterError {
            throw error
        } catch YamlError.duplicatedKeysInMapping(let fields, _) {
            throw SkillFrontmatterError.duplicateField(fields.sorted().joined(separator: ","))
        } catch YamlError.memory {
            throw SkillFrontmatterError.parserCapabilityExceeded
        } catch is YamlError {
            throw SkillFrontmatterError.invalidSyntax
        } catch {
            throw SkillFrontmatterError.parserCapabilityExceeded
        }
    }

    private func frontmatterYAML(in text: String) throws -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---",
              let closing = lines.indices.dropFirst().first(where: { lines[$0] == "---" })
        else {
            throw SkillFrontmatterError.missingDelimiter
        }
        return lines[lines.index(after: lines.startIndex)..<closing].joined(separator: "\n")
    }

    private func requiredString(_ field: String, in mapping: Node.Mapping) throws -> String {
        guard let value = mapping.first(where: { $0.key.scalar?.string == field })?.value else {
            throw SkillFrontmatterError.missingRequiredField(field)
        }
        guard case .scalar(let scalar) = value,
              value.tag.rawValue == Tag.Name.str.rawValue else {
            throw SkillFrontmatterError.invalidRequiredFieldType(field)
        }
        let trimmed = scalar.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SkillFrontmatterError.missingRequiredField(field)
        }
        return trimmed
    }

    private func checkBudget(_ root: Node) throws {
        var stack: [(node: Node, depth: Int)] = [(root, 1)]
        var nodeCount = 0
        var aliasCount = 0
        var anchorOccurrences: [ObjectIdentifier: Int] = [:]

        while let current = stack.popLast() {
            guard current.depth <= budget.maxDepth else {
                throw SkillFrontmatterError.depthBudgetExceeded
            }
            nodeCount += 1
            guard nodeCount <= budget.maxNodes else {
                throw SkillFrontmatterError.nodeBudgetExceeded
            }
            if let anchor = current.node.anchor {
                let identifier = ObjectIdentifier(anchor)
                let occurrences = anchorOccurrences[identifier, default: 0] + 1
                anchorOccurrences[identifier] = occurrences
                if occurrences > 1 {
                    aliasCount += 1
                    guard aliasCount <= budget.maxAliases else {
                        throw SkillFrontmatterError.aliasBudgetExceeded
                    }
                }
            }
            switch current.node {
            case .scalar, .alias:
                break
            case .sequence(let sequence):
                stack.append(contentsOf: sequence.map { ($0, current.depth + 1) })
            case .mapping(let mapping):
                for pair in mapping {
                    stack.append((pair.key, current.depth + 1))
                    stack.append((pair.value, current.depth + 1))
                }
            }
        }
    }
}

nonisolated extension SkillValidationResult {
    static func invalidFrontmatter(_ error: SkillFrontmatterError) -> SkillValidationResult {
        let detail: String
        switch error.category {
        case .syntax:
            detail = "YAML frontmatter has invalid syntax."
        case .format:
            detail = "YAML frontmatter must be one mapping with unique, non-empty string name and description fields."
        case .capability:
            detail = "YAML frontmatter could not be parsed within the supported parser capability."
        case .budget:
            detail = "YAML frontmatter exceeds the bounded parsing limits."
        }
        return SkillValidationResult(
            status: .invalid,
            messages: [ValidationMessage(id: "frontmatter-\(error.category.rawValue)", severity: .error, message: detail)],
            risks: []
        )
    }
}

nonisolated struct SkillIDNormalizer {
    func normalize(_ name: String) -> String {
        var result = ""
        var previousWasSeparator = false

        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }

        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

nonisolated struct SkillValidator {
    var largeAssetThreshold: Int64 = 5 * 1024 * 1024

    private let fileManager: FileManager
    private let parser: SkillFrontmatterParser
    private let normalizer: SkillIDNormalizer
    private let readAccess: ManifestReadAccess

    init(
        fileManager: FileManager = .default,
        parser: SkillFrontmatterParser = SkillFrontmatterParser(),
        normalizer: SkillIDNormalizer = SkillIDNormalizer(),
        readAccess: ManifestReadAccess? = nil
    ) {
        self.fileManager = fileManager
        self.parser = parser
        self.normalizer = normalizer
        self.readAccess = readAccess ?? ManifestReadAccess(fileManager: fileManager)
    }

    func validate(
        skillDirectory: URL,
        rootDirectory: URL? = nil,
        knownSkillIDs: Set<String> = [],
        sourceMetadataPresent: Bool = true
    ) -> SkillValidationResult {
        do {
            let manifest = try ContentManifestBuilder(fileManager: fileManager, readAccess: readAccess)
                .build(for: skillDirectory, authorizedRoot: rootDirectory ?? skillDirectory)
            let nodes = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.relativePath, $0) })
            guard let entry = resolvedEntry("SKILL.md", in: nodes, directory: skillDirectory), entry.kind == .file else {
                return invalid("missing-skill-file", "A readable SKILL.md file within this Skill is required.")
            }
            let bytes = try readAccess.data(at: skillDirectory.appendingPathComponent(entry.relativePath))
            guard let contents = String(data: bytes, encoding: .utf8) else {
                return invalid("unreadable-skill-file", "SKILL.md could not be read as UTF-8.")
            }
            return validate(contents: contents, manifest: manifest, skillDirectory: skillDirectory,
                            knownSkillIDs: knownSkillIDs, sourceMetadataPresent: sourceMetadataPresent)
        } catch FileAccessFailure.symlinkEscapesRoot(let path) {
            return SkillValidationResult(
                status: .invalid,
                messages: [validationError("symlink-escape-\(path)", "Symbolic link leaves the authorized directory.")],
                risks: [RiskMarker(id: "symlink-escape-\(path)", kind: .symlink, path: path, detail: "External content was not read.")]
            )
        } catch FileAccessFailure.symlinkCycle(let path) {
            return invalid("symlink-cycle-\(path)", "Symbolic link cycle prevents static validation.")
        } catch ContentManifestFailure.readFailed(let path, let stage) {
            return invalid(stage == .symbolicLinkTarget ? "broken-symlink-\(path)" : "unreadable-node-\(path)",
                           stage == .symbolicLinkTarget
                            ? "Broken symlink or unreadable target prevents static validation."
                            : "The content tree could not be read completely (\(stage.rawValue)).")
        } catch {
            return invalid("invalid-content-tree", "Static validation was blocked: \(error)")
        }
    }

    func validate(
        contents: String,
        manifest: ContentManifest,
        skillDirectory: URL,
        knownSkillIDs: Set<String> = [],
        sourceMetadataPresent: Bool = true,
        frontmatter parsedFrontmatter: SkillFrontmatter? = nil
    ) -> SkillValidationResult {
        let nodes = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.relativePath, $0) })
        guard let entry = resolvedEntry("SKILL.md", in: nodes, directory: skillDirectory), entry.kind == .file else {
            return invalid("missing-skill-file", "A readable SKILL.md file within this Skill is required.")
        }
        guard entry.byteDigest == SHA256Digest.hex(Data(contents.utf8)) else {
            return invalid("content-changed", "SKILL.md changed after its manifest was observed.")
        }
        let frontmatter: SkillFrontmatter
        if let parsedFrontmatter {
            frontmatter = parsedFrontmatter
        } else {
            do {
                frontmatter = try parser.parse(contents)
            } catch let error as SkillFrontmatterError {
                return .invalidFrontmatter(error)
            } catch {
                return .invalidFrontmatter(.parserCapabilityExceeded)
            }
        }
        let skillID = normalizer.normalize(frontmatter.name)
        guard !skillID.isEmpty else { return invalid("empty-skill-id", "Normalized skill id is empty.") }
        guard !knownSkillIDs.contains(skillID) else {
            return invalid("skill-id-conflict", "Skill id conflicts with an existing skill.")
        }

        var messages: [ValidationMessage] = []
        var risks: [RiskMarker] = []
        if normalizer.normalize(skillDirectory.lastPathComponent) != skillID {
            messages.append(warning("name-directory-mismatch", "Frontmatter name does not match directory name."))
        }
        if frontmatter.description.count < 12 || frontmatter.description.count > 500 {
            messages.append(warning("description-length", "Description length should be reviewed."))
        }
        if !sourceMetadataPresent {
            messages.append(warning("missing-source-metadata", "Source metadata is missing."))
        }

        let access = FileAccessService(fileManager: fileManager)
        for reference in markdownLinkTargets(in: contents) {
            if reference.hasPrefix("http://") || reference.hasPrefix("https://") {
                risks.append(RiskMarker(id: "external-url-\(reference)", kind: .externalURL, path: reference, detail: "External URL referenced by SKILL.md."))
                continue
            }
            if reference.hasPrefix("#") || reference.hasPrefix("mailto:") { continue }
            let raw = reference.components(separatedBy: "#").first ?? reference
            let path = raw.removingPercentEncoding ?? raw
            let target = skillDirectory.appendingPathComponent(path).standardizedFileURL
            if path.hasPrefix("/") || !access.isDescendant(target, of: skillDirectory, resolvingSymlinks: false) {
                risks.append(RiskMarker(id: "cross-directory-\(reference)", kind: .crossDirectoryReference, path: reference, detail: "Reference points outside the skill directory; no external path was read."))
                continue
            }
            if resolvedEntry(path, in: nodes, directory: skillDirectory) == nil {
                messages.append(warning("missing-reference-\(reference)", "Referenced file does not exist with this exact spelling: \(reference)"))
            }
        }
        if contents.contains("http://") || contents.contains("https://") {
            risks.append(RiskMarker(id: "external-url-content", kind: .externalURL, path: "SKILL.md", detail: "SKILL.md contains an external URL."))
        }
        for node in manifest.entries {
            let path = node.relativePath
            let url = skillDirectory.appendingPathComponent(path)
            if node.kind == .symbolicLink, let target = node.symbolicLinkTarget {
                let resolved = url.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
                if target.hasPrefix("/") || !access.isDescendant(resolved, of: skillDirectory, resolvingSymlinks: false) {
                    messages.append(validationError("symlink-not-relocatable-\(path)", "Symbolic link cannot be copied within this Skill."))
                    risks.append(RiskMarker(id: "symlink-not-relocatable-\(path)", kind: .symlink, path: path, detail: "Link depends on content outside the copied Skill."))
                }
            }
            if (node.kind == .directory && url.lastPathComponent == "scripts")
                || (node.kind == .file && ["sh", "bash", "zsh", "py", "js", "mjs", "cjs", "rb", "pl", "ps1"].contains(url.pathExtension.lowercased())) {
                risks.append(RiskMarker(id: "script-\(path)", kind: .script, path: path, detail: "Skill contains script content; it was not executed."))
            }
            if node.kind == .file && (node.isExecutable || ["bin", "exe", "dll", "dylib", "so", "wasm"].contains(url.pathExtension.lowercased())) {
                risks.append(RiskMarker(id: "executable-\(path)", kind: .executable, path: path, detail: "Skill contains executable or potential binary content; it was not executed."))
            }
            if node.byteCount > largeAssetThreshold {
                risks.append(RiskMarker(id: "large-asset-\(path)", kind: .largeAsset, path: path, detail: "Skill contains a large asset."))
            }
        }
        let status: SkillValidationStatus = messages.contains(where: { $0.severity == .error }) ? .invalid : (messages.isEmpty && risks.isEmpty ? .valid : .warning)
        return SkillValidationResult(status: status, messages: messages, risks: risks)
    }

    private func resolvedEntry(_ path: String, in nodes: [String: ContentManifestEntry], directory: URL) -> ContentManifestEntry? {
        func relativePath(_ url: URL) -> String {
            url.standardizedFileURL == directory.standardizedFileURL ? "."
                : String(url.path.dropFirst(directory.standardizedFileURL.path.count + 1)).precomposedStringWithCanonicalMapping
        }
        let resolved = try? FileAccessService(fileManager: fileManager).resolvePath(path, relativeTo: directory, within: directory) { url, requiresDirectory in
            guard let node = nodes[relativePath(url)] else { throw FileAccessFailure.unreadable(path: url.path) }
            if node.kind == .symbolicLink { return node.symbolicLinkTarget }
            guard !requiresDirectory || node.kind == .directory else { throw FileAccessFailure.unreadable(path: url.path) }
            return nil
        }
        return resolved.flatMap { nodes[relativePath($0)] }
    }

    private func markdownLinkTargets(in contents: String) -> [String] {
        let pattern = #"\[[^\]]+\]\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: contents, range: NSRange(contents.startIndex..<contents.endIndex, in: contents)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: contents) else { return nil }
            return String(contents[range])
        }
    }

    private func warning(_ id: String, _ message: String) -> ValidationMessage {
        ValidationMessage(id: id, severity: .warning, message: message)
    }

    private func validationError(_ id: String, _ message: String) -> ValidationMessage {
        ValidationMessage(id: id, severity: .error, message: message)
    }

    private func invalid(_ id: String, _ message: String) -> SkillValidationResult {
        SkillValidationResult(status: .invalid, messages: [validationError(id, message)], risks: [])
    }
}
