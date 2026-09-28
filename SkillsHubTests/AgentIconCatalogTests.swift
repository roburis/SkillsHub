import Testing
@testable import SkillsHub

struct AgentIconCatalogTests {
    @Test func everyBuiltInAgentHasUniqueVendoredAsset() {
        let specifications = AgentKind.allCases.map(AgentIconCatalog.specification(for:))

        #expect(specifications.allSatisfy { $0.assetName != nil })
        #expect(Set(specifications.compactMap(\.assetName)).count == AgentKind.allCases.count)
    }

    @Test func renderingModesPreserveColorAssetsAndTintMonochromeAssets() {
        #expect(AgentIconCatalog.specification(for: .claudeCode).renderingMode == .original)
        #expect(AgentIconCatalog.specification(for: .geminiCLI).renderingMode == .original)
        #expect(AgentIconCatalog.specification(for: .codex).renderingMode == .template)
        #expect(AgentIconCatalog.specification(for: .cursor).renderingMode == .template)
        #expect(AgentIconCatalog.specification(for: .hermesAgent).renderingMode == .template)
    }

    @Test func opticalMetricsAndCustomFallbackStayInsideSharedContainerContract() {
        for agent in AgentKind.allCases {
            let specification = AgentIconCatalog.specification(for: agent)
            #expect((0.75 ... 0.9).contains(specification.opticalScale))
            #expect(abs(specification.verticalOffset) <= 0.05)
        }

        let fallback = AgentIconCatalog.specification(for: nil)
        #expect(fallback.assetName == nil)
        #expect(fallback.fallbackSystemImage == "person.crop.circle")
        #expect(fallback.renderingMode == .template)
    }
}
