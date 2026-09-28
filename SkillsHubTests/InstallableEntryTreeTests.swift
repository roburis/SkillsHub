import Testing
@testable import SkillsHub

struct InstallableEntryTreeTests {
    @Test func warningReasonPrefersValidationMessage() {
        let entry = InstallableEntry(
            id: "review", name: "Review", path: "/review", kind: .skill,
            validation: SkillValidationResult(
                status: .warning,
                messages: [ValidationMessage(id: "message", severity: .warning, message: "Actionable message")],
                risks: [RiskMarker(id: "risk", kind: .script, path: "script.sh", detail: "Risk detail")]
            )
        )

        #expect(entry.warningReason == "Actionable message")
    }
}
