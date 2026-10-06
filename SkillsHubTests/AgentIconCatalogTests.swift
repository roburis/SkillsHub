import Testing
import AppKit
@testable import SkillsHub

struct AgentIconCatalogTests {
    @MainActor @Test(arguments: [AgentKind.codex, .claudeCode])
    func desktopIconUsesBundleResourceAndFallsBackWhenUnavailable(agent: AgentKind) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".tmp/agent-icon-\(UUID().uuidString).app")
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist: [String: Any] = ["CFBundleIdentifier": "test.agent-icon", "CFBundleIconFile": "Agent.png"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        #expect(await AgentIconCatalog.desktopIconData(at: nil) == nil)
        #expect(await AgentIconCatalog.desktopIconData(at: root.path) == nil)
        let descriptor = InstalledAgentDescriptor(id: agent.rawValue, displayName: agent.displayName, agent: agent,
                                                  isCustom: false, isDetected: true, isUnresolved: false,
                                                  globalCapability: .available(path: nil), installationCategory: .desktop,
                                                  desktopAppPath: root.path)
        #expect(AgentPresentation(descriptor: descriptor).iconSpecification == AgentIconCatalog.specification(for: agent))
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: resources.appendingPathComponent("Agent.png"))
        let loaded = try #require(await AgentIconCatalog.desktopIconData(at: root.path))
        #expect(NSImage(data: loaded)?.size == NSSize(width: 32, height: 32))
        try Data("invalid image".utf8).write(to: resources.appendingPathComponent("Agent.png"))
        let invalid = try #require(await AgentIconCatalog.desktopIconData(at: root.path))
        #expect(NSImage(data: invalid) == nil)
        try FileManager.default.removeItem(at: resources.appendingPathComponent("Agent.png"))
        #expect(await AgentIconCatalog.desktopIconData(at: descriptor.desktopAppPath) == nil)
        #expect(AgentIconCatalog.specification(for: .codex).assetName == "CodexAgentIcon")
        #expect(AgentIconCatalog.specification(for: .claudeCode).assetName == "ClaudeAgentIcon")
    }

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
