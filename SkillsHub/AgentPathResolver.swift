import Foundation
import Darwin

nonisolated struct UserHomeDirectoryResolver {
    func homeDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManagerHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        posixHomeDirectory: URL? = Self.posixHomeDirectory()
    ) -> URL {
        let environmentHomeDirectory = environment["HOME"].flatMap { path -> URL? in
            guard !path.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let candidates: [URL?] = [
            posixHomeDirectory,
            environmentHomeDirectory,
            fileManagerHomeDirectory
        ]

        for candidate in candidates.compactMap({ $0 }) {
            if let unsandboxed = homeDirectoryOutsideSandboxContainer(from: candidate) {
                return unsandboxed
            }
            return candidate.standardizedFileURL
        }

        return fileManagerHomeDirectory.standardizedFileURL
    }

    static func currentHomeDirectory() -> URL {
        Self().homeDirectory()
    }

    private static func posixHomeDirectory() -> URL? {
        guard let passwd = getpwuid(getuid()),
              let directory = passwd.pointee.pw_dir else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }

    private func homeDirectoryOutsideSandboxContainer(from url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        let marker = "/Library/Containers/"
        guard let markerRange = path.range(of: marker) else {
            return nil
        }

        let suffix = path[markerRange.upperBound...]
        guard let dataRange = suffix.range(of: "/Data") else {
            return nil
        }
        let bundleComponent = suffix[..<dataRange.lowerBound]
        let remainder = suffix[dataRange.upperBound...]
        guard !bundleComponent.isEmpty,
              remainder.isEmpty || remainder.first == "/" else {
            return nil
        }

        let homePath = String(path[..<markerRange.lowerBound])
        guard !homePath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL
    }
}

nonisolated struct AgentPathResolver {
    func globalSkillsDirectory(for agent: AgentKind, environment: [String: String] = ProcessInfo.processInfo.environment, homeDirectory: URL = UserHomeDirectoryResolver.currentHomeDirectory()) -> URL {
        switch agent {
        case .claudeCode:
            return URL(fileURLWithPath: environment["CLAUDE_CONFIG_DIR"] ?? homeDirectory.appendingPathComponent(".claude").path, isDirectory: true).appendingPathComponent("skills", isDirectory: true)
        case .codex:
            return URL(fileURLWithPath: environment["CODEX_HOME"] ?? homeDirectory.appendingPathComponent(".codex").path, isDirectory: true).appendingPathComponent("skills", isDirectory: true)
        case .cursor:
            return homeDirectory.appendingPathComponent(".cursor/skills", isDirectory: true)
        case .hermesAgent:
            return URL(fileURLWithPath: environment["HERMES_HOME"] ?? homeDirectory.appendingPathComponent(".hermes").path, isDirectory: true).appendingPathComponent("skills", isDirectory: true)
        case .geminiCLI:
            return homeDirectory.appendingPathComponent(".gemini/skills", isDirectory: true)
        }
    }
}
