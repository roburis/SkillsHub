import Foundation

nonisolated enum AgentIconRenderingMode: Equatable {
    case original
    case template
}

nonisolated struct AgentIconSpecification: Equatable {
    var assetName: String?
    var fallbackSystemImage: String
    var renderingMode: AgentIconRenderingMode
    var opticalScale: Double
    var verticalOffset: Double
}

nonisolated enum AgentIconCatalog {
    static let customFallback = AgentIconSpecification(
        assetName: nil,
        fallbackSystemImage: "person.crop.circle",
        renderingMode: .template,
        opticalScale: 0.76,
        verticalOffset: 0
    )

    static func specification(for agent: AgentKind?) -> AgentIconSpecification {
        guard let agent else {
            return customFallback
        }

        switch agent {
        case .claudeCode:
            return AgentIconSpecification(assetName: "ClaudeAgentIcon", fallbackSystemImage: "sparkles", renderingMode: .original, opticalScale: 0.84, verticalOffset: 0)
        case .codex:
            return AgentIconSpecification(assetName: "CodexAgentIcon", fallbackSystemImage: "sparkles", renderingMode: .template, opticalScale: 0.82, verticalOffset: 0)
        case .cursor:
            return AgentIconSpecification(assetName: "CursorAgentIcon", fallbackSystemImage: "cursorarrow.click", renderingMode: .template, opticalScale: 0.82, verticalOffset: 0)
        case .hermesAgent:
            return AgentIconSpecification(assetName: "HermesAgentIcon", fallbackSystemImage: "paperplane", renderingMode: .template, opticalScale: 0.84, verticalOffset: 0)
        case .geminiCLI:
            return AgentIconSpecification(assetName: "GeminiCLIAgentIcon", fallbackSystemImage: "diamond", renderingMode: .original, opticalScale: 0.86, verticalOffset: 0)
        }
    }
}
