import Darwin
import Foundation
import Security
import CoreServices

/// Static proof for one supported Agent. Directory observations are not installation evidence.
nonisolated struct AgentInstallationEvidence: Codable, Hashable, Sendable {
    let agent: AgentKind
    let digest: String
    let cliInstalled: Bool?
    let desktopAppPath: String?

    init(agent: AgentKind, digest: String, cliInstalled: Bool? = nil, desktopAppPath: String? = nil) {
        self.agent = agent
        self.digest = digest
        self.cliInstalled = cliInstalled
        self.desktopAppPath = desktopAppPath
    }

    var category: AgentInstallationCategory {
        if desktopAppPath != nil { return cliInstalled == true ? .both : .desktop }
        return .cli // Historical evidence was exclusively verified CLI evidence.
    }
}

nonisolated enum AgentInstallationCategory: String, Codable, Hashable, Sendable {
    case absent, unverifiable, cli, desktop, both
}

nonisolated enum AgentInstallationResult: Equatable, Sendable {
    case absent
    case unverifiable
    case present(AgentInstallationEvidence)

    var evidence: AgentInstallationEvidence? {
        guard case .present(let evidence) = self else { return nil }
        return evidence
    }

    var category: AgentInstallationCategory {
        switch self {
        case .absent: .absent
        case .unverifiable: .unverifiable
        case .present(let evidence): evidence.category
        }
    }
}

nonisolated struct AgentInstallationDetector: Sendable {
    struct Candidate: Sendable {
        let entry: URL
        let root: URL
    }

    private let candidates: @Sendable (AgentKind, URL) -> [Candidate]
    private let desktopCandidates: @Sendable (AgentKind, URL) throws -> [URL]
    private let verifyCLI: @Sendable (URL, String) throws -> [String]
    private let verifyDesktop: @Sendable (URL, String) throws -> [String]

    init(
        candidates: @escaping @Sendable (AgentKind, URL) -> [Candidate] = Self.fixedCandidates,
        desktopCandidates: @escaping @Sendable (AgentKind, URL) throws -> [URL] = Self.registeredDesktopCandidates,
        verifyCLI: @escaping @Sendable (URL, String) throws -> [String] = Self.validatedHashes,
        verifyDesktop: @escaping @Sendable (URL, String) throws -> [String] = Self.validatedDesktopHashes
    ) {
        self.candidates = candidates
        self.desktopCandidates = desktopCandidates
        self.verifyCLI = verifyCLI
        self.verifyDesktop = verifyDesktop
    }

    static func fixedCandidates(agent: AgentKind, home: URL) -> [Candidate] {
        guard agent == .codex || agent == .claudeCode else { return [] }
        let executable = agent == .codex ? "codex" : "claude"
        return [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local"), home.appendingPathComponent(".local")].map {
            Candidate(entry: $0.appendingPathComponent("bin/\(executable)"), root: $0)
        }
    }

    func detect(agent: AgentKind, home: URL) -> AgentInstallationResult {
        guard let requirement = Self.requirement(for: agent), let desktopRequirement = Self.desktopRequirement(for: agent) else { return .unverifiable }
        var proofs: [String] = []
        var unknown = false
        for candidate in candidates(agent, home) {
            do {
                let url = try Self.resolve(candidate)
                let before = try Self.identity(url)
                let hashes = try verifyCLI(url, requirement)
                guard try Self.resolve(candidate) == url, try Self.identity(url) == before else { throw Failure.invalid }
                proofs.append(([url.path, before] + hashes).joined(separator: "|"))
            } catch Failure.absent {
                continue
            } catch {
                unknown = true
            }
        }
        let cliInstalled = !proofs.isEmpty
        var desktopAppPath: String?
        do {
            for url in try desktopCandidates(agent, home) {
                do {
                    let before = try Self.desktopIdentity(url)
                    let hashes = try verifyDesktop(url, desktopRequirement)
                    guard try Self.desktopIdentity(url) == before else { throw Failure.invalid }
                    proofs.append(([url.standardizedFileURL.path, before] + hashes).joined(separator: "|"))
                    desktopAppPath = url.standardizedFileURL.path
                } catch Failure.absent {
                    continue
                } catch {
                    unknown = true
                }
            }
        } catch {
            unknown = true
        }
        guard proofs.isEmpty == false else { return unknown ? .unverifiable : .absent }
        let rules = "static-native-v2|offline|signed-cli-and-desktop|\(requirement)|\(desktopRequirement)"
        let digest = SHA256Digest.hex(Data(([rules] + Array(Set(proofs)).sorted()).joined(separator: "\n").utf8))
        return .present(AgentInstallationEvidence(agent: agent, digest: digest, cliInstalled: cliInstalled, desktopAppPath: desktopAppPath))
    }

    static func registeredDesktopCandidates(agent: AgentKind, home: URL) throws -> [URL] {
        guard let bundleID = desktopBundleID(for: agent) else { return [] }
        let fixed = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
            .map { $0.appendingPathComponent(agent == .codex ? "Codex.app" : "Claude.app", isDirectory: true) }
        var error: Unmanaged<CFError>?
        let registered = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, &error)?.takeRetainedValue() as? [URL] ?? []
        if let error = error?.takeRetainedValue(), CFErrorGetCode(error) != kLSApplicationNotFoundErr {
            throw error
        }
        return Array(Set(fixed + registered)).sorted { $0.path < $1.path }
    }

    private static func desktopBundleID(for agent: AgentKind) -> String? {
        switch agent {
        case .codex: "com.openai.codex"
        case .claudeCode: "com.anthropic.claudefordesktop"
        default: nil
        }
    }

    private static func desktopRequirement(for agent: AgentKind) -> String? {
        guard let bundleID = desktopBundleID(for: agent) else { return nil }
        let team = agent == .codex ? "2DC432GLL2" : "Q6L2SF6YDW"
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(bundleID)\""
    }

    private static func desktopIdentity(_ url: URL) throws -> String {
        var info = stat()
        var volume = statfs()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { throw Failure.absent }
            throw Failure.invalid
        }
        guard info.st_mode & S_IFMT == S_IFDIR, statfs(url.path, &volume) == 0,
              volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw Failure.invalid }
        return "\(info.st_dev)|\(info.st_ino)|\(info.st_mtimespec.tv_sec)|\(info.st_ctimespec.tv_sec)"
    }

    private static func validatedDesktopHashes(_ url: URL, requirement text: String) throws -> [String] {
        var requirement: SecRequirement?
        var code: SecStaticCode?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures).union(.noNetworkAccess), requirement) == errSecSuccess else { throw Failure.invalid }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let values = dictionary[kSecCodeInfoCdHashes as String] as? [Data], !values.isEmpty else { throw Failure.invalid }
        return values.map { $0.map { String(format: "%02x", $0) }.joined() }.sorted()
    }

    static func requirement(for agent: AgentKind) -> String? {
        let team: String
        let identifier: String
        switch agent {
        case .codex: (team, identifier) = ("2DC432GLL2", "codex")
        case .claudeCode: (team, identifier) = ("Q6L2SF6YDW", "com.anthropic.claude-code")
        default: return nil
        }
        return "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
    }

    private enum Failure: Error { case absent, invalid }

    /// Resolve each component before following it, including parent directory links.
    static func resolve(_ candidate: Candidate) throws -> URL {
        let root = candidate.root.standardizedFileURL
        guard candidate.entry.path.hasPrefix(root.path + "/") else { throw Failure.invalid }
        var ancestor = URL(fileURLWithPath: "/")
        for component in root.pathComponents.dropFirst() {
            ancestor.appendPathComponent(component)
            var info = stat()
            guard lstat(ancestor.path, &info) == 0 else {
                if errno == ENOENT { throw Failure.absent }
                throw Failure.invalid
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalid }
        }
        var remaining = candidate.entry.path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        var current = root
        var visited = Set<String>()
        while remaining.isEmpty == false {
            let component = remaining.removeFirst()
            if component == "." { continue }
            if component == ".." {
                guard current != root else { throw Failure.invalid }
                current.deleteLastPathComponent()
                continue
            }
            let next = current.appendingPathComponent(component)
            var info = stat()
            guard lstat(next.path, &info) == 0 else {
                if errno == ENOENT && visited.isEmpty { throw Failure.absent }
                throw Failure.invalid
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                guard visited.count < 40, visited.insert(next.path).inserted else { throw Failure.invalid }
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: next.path)
                let relative: String
                if destination.hasPrefix("/") {
                    guard destination.hasPrefix(root.path + "/") else { throw Failure.invalid }
                    current = root
                    relative = String(destination.dropFirst(root.path.count + 1))
                } else {
                    relative = destination
                }
                // Process the link before any following '..'; lexical normalization
                // can erase a directory link that leaves the installation root.
                remaining = relative.split(separator: "/").map(String.init) + remaining
            } else {
                if remaining.isEmpty == false, info.st_mode & S_IFMT != S_IFDIR { throw Failure.invalid }
                current = next
            }
        }
        return current
    }

    private static func identity(_ url: URL) throws -> String {
        var info = stat()
        var volume = statfs()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              statfs(url.path, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0,
              access(url.path, R_OK) == 0 else { throw Failure.invalid }
        return "\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec)|\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec)|\(info.st_ctimespec.tv_nsec)"
    }

    private static func validatedHashes(_ url: URL, requirement text: String) throws -> [String] {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { throw Failure.invalid }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try file.read(upToCount: 8) ?? Data()
        guard header.count == 8 else { throw Failure.invalid }
        let magic = Array(header.prefix(4))
        let offsets: [UInt64]
        if magic == [0xca, 0xfe, 0xba, 0xbe] || magic == [0xca, 0xfe, 0xba, 0xbf] {
            let count = header.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let width = magic.last == 0xbf ? 32 : 20
            guard count > 0, count <= 64 else { throw Failure.invalid }
            let table = try file.read(upToCount: Int(count) * width) ?? Data()
            guard table.count == Int(count) * width else { throw Failure.invalid }
            offsets = (0..<Int(count)).map { index in
                let start = index * width + 8
                return table[start..<(start + (width == 32 ? 8 : 4))].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
        } else {
            guard [[0xcf, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf], [0xce, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xce]].contains(magic) else { throw Failure.invalid }
            offsets = [0]
        }
        var hashes: [String] = []
        for offset in offsets {
            var code: SecStaticCode?
            let attributes = [kSecCodeAttributeUniversalFileOffset: NSNumber(value: offset)] as CFDictionary
            guard SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attributes, &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures).union(.noNetworkAccess), requirement) == errSecSuccess else { throw Failure.invalid }
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                  let dictionary = information as? [String: Any],
                  let values = dictionary[kSecCodeInfoCdHashes as String] as? [Data], values.isEmpty == false else { throw Failure.invalid }
            hashes += values.map { "\(offset):" + $0.map { String(format: "%02x", $0) }.joined() }
        }
        return hashes.sorted()
    }
}
