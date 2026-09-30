import Foundation

nonisolated enum InstalledAgentCapabilityReason: String, Equatable {
    case invalidSkillsDirectory
    case missingSkillsDirectory
    case notWritable
    case unresolvedAgent
}

nonisolated enum InstalledAgentCapability: Equatable {
    case available(path: String?)
    case unavailable(InstalledAgentCapabilityReason)

    var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }
}

nonisolated struct InstalledAgentDescriptor: Equatable, Identifiable {
    var id: String
    var displayName: String
    var iconMonogram: String?
    var agent: AgentKind?
    var skillsDirectory: String?
    var isCustom: Bool
    var isDetected: Bool
    var isUnresolved: Bool
    var globalCapability: InstalledAgentCapability
    var installationCategory: AgentInstallationCategory? = nil

    var isVisibleOnCards: Bool {
        !isUnresolved
    }

    var isVisibleInSidebar: Bool {
        isVisibleOnCards && (isCustom || [.cli, .desktop, .both].contains(installationCategory))
    }
}

nonisolated struct InstalledAgentIdentityIssue: Equatable, Identifiable {
    var agentID: String
    var detail: String

    var id: String { agentID }
}

nonisolated struct InstalledAgentDescriptorResult: Equatable {
    var descriptors: [InstalledAgentDescriptor]
    var issues: [InstalledAgentIdentityIssue]
}

nonisolated struct InstalledAgentDescriptorBuilder {
    func build(
        detections: [AgentDetectionSnapshot],
        configurations: [AgentConfigurationRecord],
        links: [AgentLinkRecord]
    ) -> InstalledAgentDescriptorResult {
        var descriptors = configurations.map { configuration in
            let detection = detections.first { $0.agentID == configuration.id }
            let globalCapability = configuration.agent == nil
                ? customGlobalCapability(detection: detection, configuration: configuration)
                : .available(path: configuration.skillsDirectory ?? detection?.skillsDirectory)
            return InstalledAgentDescriptor(
                id: configuration.id,
                displayName: configuration.displayName,
                iconMonogram: configuration.iconMonogram,
                agent: configuration.agent,
                skillsDirectory: configuration.skillsDirectory ?? detection?.skillsDirectory,
                isCustom: configuration.agent == nil,
                isDetected: detection?.detected == true,
                isUnresolved: false,
                globalCapability: globalCapability,
                installationCategory: detection?.installationCategory ?? (detection?.installationEvidence?.category)
            )
        }

        let representedIDs = Set(descriptors.map(\.id))
        let orphanIDs = Set(links.map(\.agentID)).filter { agentID in
            !representedIDs.contains(agentID)
                && AgentKind(rawValue: agentID) == nil
        }
        descriptors.append(contentsOf: orphanIDs.map { unresolvedDescriptor(agentID: $0, displayName: $0) })
        descriptors.sort(by: stableDescriptorOrder)

        let issues = descriptors
            .filter(\.isUnresolved)
            .map { descriptor in
                InstalledAgentIdentityIssue(
                    agentID: descriptor.id,
                    detail: "Agent configuration is missing for persisted link identity \(descriptor.id)."
                )
            }
        return InstalledAgentDescriptorResult(descriptors: descriptors, issues: issues)
    }

    private func customGlobalCapability(
        detection: AgentDetectionSnapshot?,
        configuration: AgentConfigurationRecord
    ) -> InstalledAgentCapability {
        let path = configuration.skillsDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard path.hasPrefix("/") else {
            return .unavailable(.invalidSkillsDirectory)
        }
        guard detection?.skillsDirectoryExists == true else {
            return .unavailable(.missingSkillsDirectory)
        }
        guard detection?.writable == true else {
            return .unavailable(.notWritable)
        }
        return .available(path: path)
    }

    private func unresolvedDescriptor(agentID: String, displayName: String) -> InstalledAgentDescriptor {
        InstalledAgentDescriptor(
            id: agentID,
            displayName: displayName,
            iconMonogram: nil,
            agent: nil,
            skillsDirectory: nil,
            isCustom: true,
            isDetected: false,
            isUnresolved: true,
            globalCapability: .unavailable(.unresolvedAgent)
        )
    }

    private func stableDescriptorOrder(_ lhs: InstalledAgentDescriptor, _ rhs: InstalledAgentDescriptor) -> Bool {
        let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        return lhs.id < rhs.id
    }
}
