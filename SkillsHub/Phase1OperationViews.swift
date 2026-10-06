import SwiftUI

struct Phase1TasksView: View {
    var tasks: [Phase1TaskRecord]
    var language: AppLanguage = .english
    @Binding var expandedTaskIDs: Set<UUID>
    @Binding var scrollID: UUID?
    var recheck: () -> Void = {}
    var openObject: (Phase1TaskRecord) -> Void = { _ in }
    var openAgent: ((String) -> Void)? = nil
    var openDetails: ((UUID) -> Void)? = nil

    var body: some View {
        if tasks.isEmpty {
            VStack(spacing: 12) {
                ContentUnavailableView(
                    localized("No pending operations"),
                    systemImage: "checklist",
                    description: Text(localized("No recovery record is pending. This does not assert that every managed object is healthy."))
                )
                Button(localized("Re-check current facts"), action: recheck)
                    .accessibilityIdentifier("recheck-recovery-facts")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Button(localized("Re-check current facts"), action: recheck)
                            .accessibilityHint(localized("Reads current content, relationship, metadata, and retained-material facts without replaying an action."))
                            .accessibilityIdentifier("recheck-recovery-facts")
                        Spacer()
                    }
                    taskGroup("Waiting for confirmation", phase: .waitingConfirmation)
                    taskGroup("Running", phases: [.preparing, .executing, .observing, .verifying])
                    taskGroup("Needs attention", phase: .needsAttention)
                    taskGroup("Recently completed", phase: .completed)
                }
                .scrollTargetLayout()
                .padding(20)
            }
            .scrollPosition(id: $scrollID)
            .accessibilityIdentifier("phase1-task-list")
        }
    }

    private func localized(_ text: String) -> String {
        SkillsHubLocalization().localized(text, language: language)
    }

    @ViewBuilder
    private func taskGroup(_ title: String, phase: Phase1OperationPhase) -> some View {
        taskGroup(title, phases: [phase])
    }

    @ViewBuilder
    private func taskGroup(_ title: String, phases: Set<Phase1OperationPhase>) -> some View {
        let records = tasks.filter { phases.contains($0.phase) }
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(SkillsHubLocalization().localized(title, language: language))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(records) { task in
                    Phase1TaskRow(
                        task: task,
                        language: language,
                        isExpanded: expandedTaskIDs.contains(task.id),
                        toggleExpanded: {
                            if expandedTaskIDs.contains(task.id) {
                                expandedTaskIDs.remove(task.id)
                            } else {
                                expandedTaskIDs.insert(task.id)
                            }
                        },
                        openObject: openObject,
                        openAgent: openAgent,
                        openDetails: openDetails
                    )
                    .id(task.id)
                }
            }
        }
    }
}

struct Phase1TaskRow: View {
    var task: Phase1TaskRecord
    var language: AppLanguage
    var isExpanded: Bool
    var toggleExpanded: () -> Void
    var openObject: (Phase1TaskRecord) -> Void
    var openAgent: ((String) -> Void)?

    var isDetailPage = false
    var openDetails: ((UUID) -> Void)? = nil
    var settleMaterials: ((UUID) -> Void)? = nil
    var isSettlingMaterials = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isDetailPage {
                taskLabel.padding(.bottom, 24)
            } else {
            Button {
                toggleExpanded()
            } label: {
                HStack(alignment: .top) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .accessibilityHidden(true)
                    taskLabel
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityValue(localized(isExpanded ? "Expanded" : "Collapsed"))
            .accessibilityHint(localized("Press to show or hide the immutable action evidence and current-object links."))
            .accessibilityIdentifier("phase1-task-\(task.id.uuidString)")
            }
            if isExpanded {
                taskDetails
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private var taskLabel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(localized(task.title), systemImage: icon)
                Spacer()
                Text(localized(task.phase.presentationLabel))
                    .foregroundStyle(.secondary)
                Text(task.updatedAt, style: .time)
                    .foregroundStyle(.secondary)
            }
            Text(localized(task.result))
                .font(.callout)
                .foregroundStyle(task.phase == .needsAttention ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var taskDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let plan = task.operationPlan {
                LabeledContent(localized("Operation kind"), value: plan.kind.rawValue)
                LabeledContent(localized("Root"), value: plan.rootPath)
                LabeledContent(localized("Generation"), value: String(plan.expectedGeneration))
                if let schema = plan.initialMetadata?.schemaVersion {
                    LabeledContent(localized("Schema"), value: String(schema))
                }
                Text(localized("Planned steps"))
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(localized(step))").font(.caption)
                }
                Text(localized("Planned writes"))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("task-planned-writes-\(task.id.uuidString)")
                ForEach(plan.expectedWrites, id: \.self) { Text($0).font(.caption.monospaced()) }
                Text(localized("Excluded actions"))
                    .font(.subheadline.weight(.semibold))
                ForEach(plan.excludedActions, id: \.self) { Text(localized($0)).font(.caption) }
                Text(localized("Recorded steps and results"))
                    .font(.subheadline.weight(.semibold))
            }
            if let evidence = task.relationEvidence {
                relationEvidence(evidence)
                Divider()
            }
            if let recovery = task.recoveryEvidence {
                recoveryEvidence(recovery)
                if let materials = recovery.creationMaterials, isDetailPage {
                    Text(localized("Creation materials"))
                        .font(.subheadline.weight(.semibold))
                    Text(materials.path).font(.caption.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("creation-material-path")
                    Text(localized(materials.detail))
                        .accessibilityIdentifier("creation-material-qualification")
                    Text(localized("Only this recorded empty directory is considered. Current facts are checked again when you act."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let settleMaterials {
                        Button(localized(isSettlingMaterials ? "Settling creation materials…" : "Settle empty creation directory")) {
                            settleMaterials(task.id)
                        }
                        .disabled(!materials.canSettle || isSettlingMaterials)
                        .accessibilityIdentifier("settle-creation-materials")
                    }
                }
                Divider()
            }
            ForEach(task.events) { event in
                HStack(alignment: .firstTextBaseline) {
                    Text(localized(event.phase.presentationLabel))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 132, alignment: .leading)
                    Text(localized(event.message))
                }
            }
            Text("\(localized("Evidence")): \(task.planDigest)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(localized("Operation")) \(task.id.uuidString): \(localized(task.result))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(localized(task.safeNextStep))
                .accessibilityIdentifier("task-safe-next-step-\(task.id.uuidString)")
            if !isDetailPage, let openDetails {
                Button(localized("Operation Details")) { openDetails(task.id) }
                    .accessibilityIdentifier("task-open-details-\(task.id.uuidString)")
            }
            Button(localized(openObjectTitle)) {
                openObject(task)
            }
            .accessibilityHint(openObjectHint)
            .accessibilityIdentifier("task-open-skill-\(task.id.uuidString)")
            if let evidence = task.relationEvidence, let openAgent {
                Button("\(localized("View current")) \(evidence.agentDisplayName)") {
                    openAgent(evidence.relation.agentID)
                }
                .accessibilityHint(localized("Navigates to the current Agent facts without replaying this task."))
                .accessibilityIdentifier("task-open-agent-\(task.id.uuidString)")
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func recoveryEvidence(_ evidence: Phase1RecoveryEvidence) -> some View {
        Text(localized("Current facts"))
            .font(.subheadline.weight(.semibold))
        ForEach(Array(evidence.components.enumerated()), id: \.offset) { _, component in
            VStack(alignment: .leading, spacing: 2) {
                Text("\(localized(component.kind)): \(localized(component.state.presentationLabel))")
                Text(component.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text(localized(component.detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(localized(component.kind)): \(localized(component.state.presentationLabel)). \(component.path). \(localized(component.detail))"
            )
            .accessibilityIdentifier("recovery-component-\(component.kind)")
        }
    }

    @ViewBuilder
    private func relationEvidence(_ evidence: Phase1RelationTaskEvidence) -> some View {
        Group {
            Text("\(localized("Target")): \(evidence.agentDisplayName) / \(evidence.skillName)")
                .font(.headline)
            Text("\(localized("Requested")): \(localized(evidence.desiredEnabled ? "Enabled" : "Disabled"))")
            Text("\(localized("Outcome")): \(localized(evidence.outcome))")
            Text("\(localized("Current conclusion")): \(localized(evidence.verification.presentationLabel))")
            Text(localized("Actual delta"))
                .font(.subheadline.weight(.semibold))
            ForEach(evidence.actualDelta, id: \.self) { delta in
                Text(localized(LocalizedMessage("Historical record (original): %@", arguments: [delta])))
            }
            Text(localized("Evidence limitations"))
                .font(.subheadline.weight(.semibold))
            if evidence.limitations.isEmpty {
                Text(localized("No recorded limitations."))
            } else {
                ForEach(evidence.limitations, id: \.self) { limitation in
                    Text(localized(LocalizedMessage("Historical record (original): %@", arguments: [limitation])))
                }
            }
            Text("\(localized("Safe next step")): \(localized(LocalizedMessage("Historical record (original): %@", arguments: [evidence.safeNextStep])))")
        }
        .font(.callout)
    }

    private var icon: String {
        switch task.phase {
        case .completed: "checkmark.circle"
        case .needsAttention: "exclamationmark.triangle"
        case .waitingConfirmation: "questionmark.circle"
        default: "clock.arrow.circlepath"
        }
    }

    private var openObjectTitle: String {
        if task.relationEvidence != nil { return localized("View current Skill") }
        switch task.kind {
        case .initializeRoot: return localized("View current Root")
        case .deleteBrokenLink: return localized("Return to Agent")
        case .removeLocalSource, .updateSource: return localized("Return to Sources")
        default: return localized("View authoritative object")
        }
    }

    private var openObjectHint: String {
        if task.relationEvidence != nil {
            return localized("Navigates to the current Skill facts without replaying this task.")
        }
        if task.kind == .initializeRoot {
            return localized("Returns to the current Root facts. Unknown operations are re-observed rather than replayed.")
        } else if task.kind == .deleteBrokenLink {
            return localized("Returns to the current Agent facts without replaying deletion.")
        } else if task.kind == .removeLocalSource || task.kind == .updateSource {
            return localized("Returns to the current source or parent list without replaying the recorded action.")
        } else {
            return localized("Navigates to the current source, candidate, or managed Skill facts.")
        }
    }

    private var accessibilitySummary: String {
        let base = localized(LocalizedMessage("%@. %@. Operation %@. %@. Object %@. %@", arguments: [
            localized(task.title), localized(task.phase.presentationLabel), task.id.uuidString,
            localized(task.result), task.objectID, localized(task.safeNextStep)
        ]))
        guard let evidence = task.relationEvidence else { return base }
        return base + ". " + localized(LocalizedMessage("Target %@ / %@. Requested %@. Outcome %@. Current conclusion %@. %@. %@. Safe next step %@", arguments: [
            evidence.agentDisplayName, evidence.skillName, localized(evidence.desiredEnabled ? "Enabled" : "Disabled"),
            localized(evidence.outcome), localized(evidence.verification.presentationLabel),
            localized(LocalizedMessage("Historical record (original): %@", arguments: [evidence.actualDelta.joined(separator: " ")])),
            localized(LocalizedMessage("Historical record (original): %@", arguments: [evidence.limitations.joined(separator: " ")])),
            localized(LocalizedMessage("Historical record (original): %@", arguments: [evidence.safeNextStep]))
        ]))
    }

    private func localized(_ text: String) -> String {
        SkillsHubLocalization().localized(text, language: language)
    }

    private func localized(_ message: LocalizedMessage) -> String {
        let presentation = message.isVerbatim
            ? LocalizedMessage("Historical record (original): %@", arguments: [message.template]) : message
        return SkillsHubLocalization().localized(presentation, language: language)
    }
}
