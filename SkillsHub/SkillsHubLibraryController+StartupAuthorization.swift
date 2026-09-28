import Foundation

extension SkillsHubLibraryController {
    func startupAuthorizationRequest() throws -> StartupAuthorizationRequest? {
        var targets: [StartupAuthorizationTarget] = []
        if let defaultRootTarget = defaultRootAuthorizationTargetIfNeeded() {
            targets.append(defaultRootTarget)
        }
        targets.append(contentsOf: try builtInAgentAuthorizationTargets())
        guard !targets.isEmpty else {
            return nil
        }
        return StartupAuthorizationRequest(targets: targets)
    }

    func completeStartupAuthorization(for target: StartupAuthorizationTarget, selectedURL: URL) throws {
        let normalizedSelection = selectedURL.standardizedFileURL
        let normalizedAuthorizationURL = target.authorizationURL.standardizedFileURL
        guard normalizedSelection.path == normalizedAuthorizationURL.path else {
            throw SkillsHubLibraryFailure.invalidSource(
                LocalizedMessage("Please choose the suggested folder for %@.", arguments: [target.displayName])
            )
        }
        try rememberUserSelectedAccess(to: normalizedSelection)
        switch target.kind {
        case .defaultRoot:
            _ = try inspectSelectedRoot(normalizedSelection)
        case .builtInAgent:
            refreshAgentAccessAfterStartupAuthorization()
            try endSelectedInspectionAccess(to: normalizedSelection)
        }
    }

    func authorizationTarget(for agent: AgentKind) throws -> StartupAuthorizationTarget? {
        try builtInAgentAuthorizationTargets().first {
            guard case .builtInAgent(let targetAgent) = $0.kind else {
                return false
            }
            return targetAgent == agent
        }
    }

    private func defaultRootAuthorizationTargetIfNeeded() -> StartupAuthorizationTarget? {
        guard rootURL == nil else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: defaultRootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              rootURL == nil else {
            return nil
        }
        return StartupAuthorizationTarget(
            kind: .defaultRoot,
            displayName: localization.localized("Default Root", language: language),
            authorizationURL: defaultRootURL
        )
    }

    private func builtInAgentAuthorizationTargets() throws -> [StartupAuthorizationTarget] {
        try agentPathSettings.compactMap { record in
            guard record.detected,
                  !record.isOverride,
                  !record.isWritable else {
                return nil
            }
            let authorizationURL = record.skillsDirectoryExists
                ? URL(fileURLWithPath: record.resolvedPath, isDirectory: true)
                : URL(fileURLWithPath: record.markerPath, isDirectory: true)
            guard try !inspectPersistedAccess(to: authorizationURL) else {
                return nil
            }
            return StartupAuthorizationTarget(
                kind: .builtInAgent(record.agent),
                displayName: record.agent.displayName,
                authorizationURL: authorizationURL
            )
        }
    }

    private func refreshAgentAccessAfterStartupAuthorization() {
        guard rootURL != nil else {
            return
        }
        refreshAgentLightScan()
        // Re-subscribe so the newly authorized Agent directory is watched, then re-scan
        // the authorized range.
        subscribeAndInitialScan()
        setStatus("Updated startup access.")
        errorMessage = nil
    }
}
