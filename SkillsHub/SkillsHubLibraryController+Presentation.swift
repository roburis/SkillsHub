import Foundation
import AppKit

extension SkillsHubLibraryController {
    func rebuildCatalogPresentation() {
        guard rootURL != nil else {
            catalogItems = []
            catalogItemsByID = [:]
            catalogItemsBySource = [:]
            localSourcesInspectionSnapshot = []
            return
        }
        localSourcesInspectionSnapshot = makeLocalSourcesForInspection()
        let items = presentationService.phase1Items(
            availableSkills: availableSkills,
            installedSkills: installedSkills,
            sources: localSourcesForInspection + githubSourcesForPresentation,
            enablementIntents: rootSnapshot?.metadata.enablementIntents ?? [], rootURL: rootURL
        )
        catalogItemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let visibleItems = items.filter { !missingCatalogItemIDs.contains($0.id) }
        catalogItemsBySource = visibleItems.reduce(into: [:]) { result, item in
            if let sourceID = item.source?.id { result[sourceID, default: []].append(item) }
        }
        catalogItems = visibleItems
    }

    func contentNodeObservation(for item: Phase1SkillPresentation) -> TargetObservation? {
        contentObservationSnapshot[item.id]
    }

    func entryAddress(for item: Phase1SkillPresentation) -> (path: String?, status: LocalizedMessage?) {
        let unavailable = (item.candidate?.validation ?? item.managed?.validation)?.messages
            .contains { $0.id == "missing-skill-file" || $0.id == "unreadable-skill-file" } == true
        return SkillCatalogPresentationService.entryAddress(
            directoryPath: item.contentDirectoryPath, relativeTo: rootURL?.path,
            nodeKind: contentNodeObservation(for: item)?.nodeKind,
            entryVerified: item.candidate?.checkStatus == .valid || item.candidate?.checkStatus == .warning,
            entryUnavailable: unavailable
        )
    }

    func entryAddress(for finding: AgentDirectoryFinding) -> (path: String?, status: LocalizedMessage?) {
        if [.pendingAudit, .missingSkillsDirectory, .permissionDenied, .directoryEnumerationFailed].contains(finding.type) {
            return (nil, "Skill address could not be verified.")
        }
        let descriptor = visibleInstalledAgentDescriptors.first { $0.id == finding.agentID }
        let base = descriptor?.skillsDirectory ?? descriptor?.agent.map { resolvedAgentSkillsDirectory(for: $0).path }
        let kind: TargetNodeKind = switch finding.entryKind {
        case .hubManagedSymlink, .externalSymlink: .symbolicLink
        case .brokenSymlink: .brokenSymbolicLink
        case .localDirectory: .directory
        case .plainFile: .regularFile
        case .invalid: .unreadable
        case .missing: .vacant
        }
        return SkillCatalogPresentationService.entryAddress(
            directoryPath: finding.linkPath ?? finding.sourcePath, relativeTo: base,
            nodeKind: kind, entryVerified: finding.skillFileHash != nil
        )
    }

    func rebuildRelationPresentationIndexes() {
        presentationIntents = Dictionary((rootSnapshot?.metadata.enablementIntents ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        presentationObservations = Dictionary(localState.targetObservations.map { ($0.relation.id, $0) }, uniquingKeysWith: { first, _ in first })
        presentationVerifications = Dictionary(localState.verificationRecords.map { ($0.relation.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func requestPresentationObservation() {
        presentationObservationGeneration &+= 1
        let generation = presentationObservationGeneration
        presentationObservationTask?.cancel()
        // Keep the last complete display while checking; actions requalify current access.
        isRefreshingPresentation = true
        presentationObservationTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, generation == self.presentationObservationGeneration else { return }
            let root = self.rootURL
            let sessionID = self.rootSessionLease?.id
            let rootGeneration = self.rootSnapshot?.generation
            let descriptors = self.visibleInstalledAgentDescriptors
            let targets = descriptors.reduce(into: [String: URL]()) { result, descriptor in
                let target = descriptor.skillsDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? descriptor.agent.map { self.resolvedAgentSkillsDirectory(for: $0) }
                if let target { result[descriptor.id] = target.standardizedFileURL }
            }
            let detections = Set(self.agentDetections.filter(\.detected).map(\.agentID))
            let items = Array(self.catalogItemsByID.values)
            let iconPaths = Set(descriptors.compactMap(\.desktopAppPath)).subtracting(self.observedDesktopIconPaths)
            var leases: [SecurityScopedAccessLease] = []
            defer { leases.forEach { _ = $0.end(by: $0.owner) } }
            @MainActor func contextIsCurrent() -> Bool {
                !Task.isCancelled && generation == self.presentationObservationGeneration
                    && self.rootURL == root && self.rootSessionLease?.id == sessionID
                    && self.rootSnapshot?.generation == rootGeneration
            }
            do {
                var authorizations = try await self.startupAccessStore.resolvePresentationAccess(to: Array(targets.values))
                guard contextIsCurrent() else { return }
                for target in Set(targets.values) {
                    if let authorization = authorizations[target.path], !authorization.isStale,
                       authorization.url.standardizedFileURL == target {
                        do {
                            leases.append(try self.securityScopedAccessProvider.acquire(url: authorization.url, owner: .inspection(UUID())))
                        } catch {
                            authorizations.removeValue(forKey: target.path)
                            for (id, url) in targets where url == target {
                                self.agentDirectoryAccessFailures[id] = .accessFailed(self.errorPresentation(for: error))
                            }
                        }
                    } else if self.fileManager.fileExists(atPath: target.path) {
                        for (id, url) in targets where url == target {
                            self.agentDirectoryAccessFailures[id] = .authorizationRequired
                        }
                    }
                }
                var authorizedRoot: URL?
                if let accessURL = self.rootSessionLease?.url {
                    leases.append(try self.securityScopedAccessProvider.acquire(url: accessURL, owner: .inspection(UUID())))
                    authorizedRoot = root
                }
                let result = try await Self.observePresentation(
                    root: authorizedRoot, items: items, descriptors: descriptors,
                    targets: targets, detections: detections, authorizations: authorizations,
                    fileManager: self.fileManager, iconPaths: iconPaths, resolvedRootPath: self.resolvedRootPath,
                    observations: authorizedRoot == nil ? [] : self.localState.targetObservations,
                    assets: Dictionary(self.installedSkills.map { ($0.assetID, $0) }, uniquingKeysWith: { first, _ in first })
                )
                guard contextIsCurrent() else { return }
                self.agentCapabilitySnapshot = descriptors.reduce(into: [:]) { capabilities, descriptor in
                    if let qualification = result.qualifications[descriptor.id] {
                        capabilities[descriptor.id] = self.capabilityPresentation(for: descriptor, qualification: qualification)
                    }
                }
                self.contentObservationSnapshot = result.content
                self.relationOwnershipSnapshot = result.ownership
                for (path, data) in result.icons {
                    if let image = NSImage(data: data), image.isValid, image.size != .zero {
                        self.desktopIconSnapshot[path] = image
                    }
                }
                self.observedDesktopIconPaths.formUnion(iconPaths)
            } catch {
                guard contextIsCurrent() else { return }
                self.agentCapabilitySnapshot = [:]
                self.contentObservationSnapshot = [:]
                self.relationOwnershipSnapshot = [:]
                self.handle(error)
            }
            guard contextIsCurrent() else { return }
            self.isRefreshingPresentation = false
            self.presentationObservationTask = nil
        }
    }

    func waitForPresentationObservation() async {
        while let task = presentationObservationTask { await task.value }
    }

    @concurrent nonisolated static func observePresentation(
        root: URL?, items: [Phase1SkillPresentation], descriptors: [InstalledAgentDescriptor],
        targets: [String: URL], detections: Set<String>,
        authorizations: [String: StartupAccessBookmarkResolution], fileManager: FileManager,
        iconPaths: Set<String>, resolvedRootPath: String? = nil,
        observations: [TargetObservation], assets: [UUID: InstalledSkill]
    ) async throws -> (qualifications: [String: AgentTargetQualification], content: [String: TargetObservation], icons: [String: Data], ownership: [String: RelationOwnershipClassification]) {
        var qualifications: [String: AgentTargetQualification] = [:]
        for descriptor in descriptors {
            try Task.checkCancellation()
            let target = targets[descriptor.id]
            var directory: ObjCBool = false
            let candidates = target.flatMap { fileManager.fileExists(atPath: $0.path, isDirectory: &directory) && directory.boolValue ? [$0] : nil } ?? []
            let authorization = target.flatMap { authorizations[$0.path] }
            let qualifier = AgentTargetQualifier()
            qualifications[descriptor.id] = if let agent = descriptor.agent {
                qualifier.qualify(agent: agent, detected: detections.contains(descriptor.id), candidates: candidates, authorization: authorization)
            } else {
                qualifier.qualify(customAgentID: descriptor.id, detected: detections.contains(descriptor.id), candidates: candidates, authorization: authorization)
            }
        }
        var content: [String: TargetObservation] = [:]
        if let root {
            let rootPaths = [root.path] + (resolvedRootPath.map { [$0] } ?? [])
            for item in items {
                try Task.checkCancellation()
                let path = item.contentDirectoryPath
                guard let path, let identity = item.managed?.assetID ?? item.source?.id else { continue }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard rootPaths.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) else { continue }
                // This identity locates a transient content observation, never a managed relation.
                content[item.id] = try RelationOwnershipInspector().inspect(
                    linkURL: url,
                    relation: AgentRelationIdentity(assetID: identity, agentID: "content", scope: .global),
                    canonicalTargetPath: url.path).observation
            }
        }
        var icons: [String: Data] = [:]
        for path in iconPaths {
            try Task.checkCancellation()
            if let data = await AgentIconCatalog.desktopIconData(at: path) { icons[path] = data }
        }
        var ownership: [String: RelationOwnershipClassification] = [:]
        for observation in observations {
            try Task.checkCancellation()
            guard let asset = assets[observation.relation.assetID],
                  let target = targets[observation.relation.agentID] else { continue }
            let linkName = asset.stableLinkName ?? asset.name.trimmingCharacters(in: .whitespacesAndNewlines)
            ownership[observation.relation.id] = RelationOwnershipInspector.classify(
                observation: observation, expectedLinkPath: target.appendingPathComponent(linkName).path,
                canonicalTargetPath: asset.installedPath)
        }
        return (qualifications, content, icons, ownership)

    }

    func handle(_ error: Error) {
        guard !(error is CancellationError) else { return }
        errorMessage = errorPresentation(for: error)
    }

    func setStatus(_ englishTemplate: String, _ arguments: CVarArg...) {
        statusMessage = LocalizedMessage(englishTemplate, arguments: arguments.map { String(describing: $0) })
    }

    func clearStatus() {
        statusMessage = nil
    }

    func clearError() {
        errorMessage = nil
    }

    func localized(_ message: LocalizedMessage) -> String {
        localization.localized(message, language: language)
    }

    func errorPresentation(for error: Error) -> LocalizedMessage {
        SkillsHubLocalization.errorPresentation(for: error)
    }

    func sourceName(for source: SkillSource) -> String {
        localized(presentationService.sourceName(for: source, relativeTo: rootURL))
    }
}
