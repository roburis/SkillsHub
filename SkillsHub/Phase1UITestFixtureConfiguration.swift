#if DEBUG
import AppKit
import Foundation

nonisolated struct Phase1UITestFixtureConfiguration: Hashable, Sendable {
    var runID: UUID
    var runRoot: URL
    var root: URL
    var source: URL
    var home: URL
    var authorizedFixtureParent: URL
    var faultInjection: Phase1OperationFaultInjection?
    var sourceUpdateFixture: Bool
    var agentOverflowFixture: Bool
    var githubRemovalFixture: Bool
    var githubImportFixture: Bool

    init(
        arguments: [String],
        fileManager: FileManager = .default
    ) throws {
        let runIDValue = try Self.argumentValue(after: "--skillshub-ui-fixture-run-id", in: arguments)
        guard let runID = UUID(uuidString: runIDValue) else {
            throw Phase1UITestFixtureConfigurationError.invalidArgument("The fixture run identity is not a UUID.")
        }

        let runRoot = URL(
            fileURLWithPath: try Self.argumentValue(after: "--skillshub-ui-fixture-run-root", in: arguments),
            isDirectory: true
        ).standardizedFileURL
        let root = URL(
            fileURLWithPath: try Self.argumentValue(after: "--skillshub-ui-fixture-root", in: arguments),
            isDirectory: true
        ).standardizedFileURL
        let source = URL(
            fileURLWithPath: try Self.argumentValue(after: "--skillshub-ui-fixture-source", in: arguments),
            isDirectory: true
        ).standardizedFileURL
        let home = URL(
            fileURLWithPath: try Self.argumentValue(after: "--skillshub-ui-fixture-home", in: arguments),
            isDirectory: true
        ).standardizedFileURL
        let pasteboardName = try Self.argumentValue(
            after: "--skillshub-ui-fixture-pasteboard",
            in: arguments
        )
        guard pasteboardName == "me.ledar.SkillsHub.phase1-fixture.\(runID.uuidString)" else {
            throw Phase1UITestFixtureConfigurationError.invalidArgument(
                "The fixture pasteboard does not match the run identity."
            )
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
        defer { pasteboard.clearContents() }
        guard let bookmarkValue = pasteboard.string(forType: .string),
              let bookmarkData = Data(base64Encoded: bookmarkValue) else {
            throw Phase1UITestFixtureConfigurationError.invalidArgument(
                "The fixture bookmark pasteboard is missing or invalid."
            )
        }
        var bookmarkIsStale = false
        let authorizedFixtureParent = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutImplicitStartAccessing],
            relativeTo: nil,
            bookmarkDataIsStale: &bookmarkIsStale
        ).standardizedFileURL
        guard authorizedFixtureParent == runRoot.deletingLastPathComponent().standardizedFileURL else {
            throw Phase1UITestFixtureConfigurationError.invalidPath(
                "The fixture bookmark does not resolve to the declared fixture parent."
            )
        }

        guard runRoot.lastPathComponent == runID.uuidString,
              runRoot.deletingLastPathComponent().lastPathComponent == "phase1-ui-tests",
              runRoot.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".tmp" else {
            throw Phase1UITestFixtureConfigurationError.invalidPath("The run root is not a .tmp/phase1-ui-tests/<run-id> directory.")
        }
        guard root == runRoot.appending(path: "root", directoryHint: .isDirectory).standardizedFileURL,
              source == runRoot.appending(path: "source", directoryHint: .isDirectory).standardizedFileURL,
              home == runRoot.appending(path: "home", directoryHint: .isDirectory).standardizedFileURL else {
            throw Phase1UITestFixtureConfigurationError.invalidPath("Fixture paths must be the canonical children of the run root.")
        }

        self.runID = runID
        self.runRoot = runRoot
        self.root = root
        self.source = source
        self.home = home
        self.authorizedFixtureParent = authorizedFixtureParent
        self.faultInjection = try Self.faultInjection(in: arguments)
        self.sourceUpdateFixture = arguments.contains("--skillshub-ui-source-update-fixture")
        self.agentOverflowFixture = arguments.contains("--skillshub-ui-agent-overflow-fixture")
        self.githubRemovalFixture = arguments.contains("--skillshub-ui-github-removal-fixture")
        self.githubImportFixture = arguments.contains("--skillshub-ui-github-import-fixture")
    }

    func validateAccessibleDirectories(fileManager: FileManager = .default) throws {
        for directory in [runRoot, root, source, home] {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw Phase1UITestFixtureConfigurationError.missingDirectory(directory.path)
            }
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw Phase1UITestFixtureConfigurationError.invalidPath("Fixture directories cannot be symbolic links: \(directory.path)")
            }
        }
    }

    private static func argumentValue(after flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            throw Phase1UITestFixtureConfigurationError.invalidArgument("Missing \(flag).")
        }
        return arguments[arguments.index(after: index)]
    }

    private static func faultInjection(in arguments: [String]) throws -> Phase1OperationFaultInjection? {
        guard arguments.contains("--skillshub-ui-fixture-fault") else {
            return nil
        }
        let value = try argumentValue(after: "--skillshub-ui-fixture-fault", in: arguments)
        guard value == "after-staging-copy" else {
            throw Phase1UITestFixtureConfigurationError.invalidArgument("Unsupported UI fixture fault: \(value)")
        }
        return .afterStagingCopy
    }
}

nonisolated final class Phase1UITestGitHubHTTPClient: HTTPDataClient {
    private static let commit = String(repeating: "1", count: 40)
    private static let archive = Data(base64Encoded: "H4sIAJvZsGoAA+2XTW+DIBiAPfsrSO9oRdHE4w7bmpkdtuwHOMWVzcqCmLZZ9t+H1l1c/Wg1Lk15LpBAQHjgfTGhO1FwAtk2IxymNCHRPkoJtAaiDWAp8TCuSkmzPNQRcm3Ps92qbnmOowE8ZPCxFLkIufyU7ZqQtKNfX3tzcRdCMtK/+fywCgJjE3fMUe6HK4W2+beQ0/BvI7TUwCybeOX+IYR6Fm6ID4Jf9+CJMaHHJI84/RSUZT64pTsSgzsq7otX8LIC9akBXPYE+QdNU0MvR7ph8d7Q/3tNiuGMvv+V/bxzjtPjv40crOL/HEzk38xILkhLEjjdv4ORp/zPwbT+j78GevO/3fTvls0q/8/Asfz/WLkc9gI4eFdvgEtl/P1fh7wt8Neck/8tpOL/HEzk34xYltA34z1n2Z85+uK//N9v+McOQir+z8HXoj4BC1/wgnyrwK1QKBTXwQ/uP1x7ABgAAA==")!
    private let traceURL: URL
    private let lock = NSLock()

    init(traceURL: URL) {
        self.traceURL = traceURL
    }

    func data(for request: URLRequest, maximumByteCount: Int) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, request.httpMethod == "GET" else {
            throw GitHubAPIClientFailure.networkFailure
        }
        let data: Data
        switch url.path {
        case "/repos/fixture-owner/lifecycle":
            data = Data(#"{"id":42,"name":"lifecycle","owner":{"login":"fixture-owner"},"default_branch":"main"}"#.utf8)
        case "/repos/fixture-owner/lifecycle/git/ref/heads/main":
            data = Data(#"{"ref":"refs/heads/main","object":{"type":"commit","sha":"1111111111111111111111111111111111111111"}}"#.utf8)
        case "/repos/fixture-owner/lifecycle/git/trees/\(Self.commit)":
            data = Data(#"{"tree":[{"path":"SKILL.md","mode":"100644","type":"blob","sha":"b11e86210a4ba2907a0ceff4623a6e43c39a60eb","size":84},{"path":"skills/nested/SKILL.md","mode":"100644","type":"blob","sha":"9f98dd5cb33e80d483b9d8f3fed4bf767b742529","size":88},{"path":"shared/config.json","mode":"100644","type":"blob","sha":"a084ebbde65d4e8c5ca67db54085fb84416b4102","size":17}],"truncated":false}"#.utf8)
        case "/repos/fixture-owner/lifecycle/tarball/\(Self.commit)":
            data = Self.archive
        default:
            throw GitHubAPIClientFailure.networkFailure
        }
        guard data.count <= maximumByteCount else { throw GitHubAPIClientFailure.repositoryTooLarge }
        try record(request)
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }

    private func record(_ request: URLRequest) throws {
        let record: [String: Any] = [
            "method": request.httpMethod ?? "",
            "path": request.url?.path ?? "",
            "authorization": request.value(forHTTPHeaderField: "Authorization") != nil
        ]
        let line = try JSONSerialization.data(withJSONObject: record) + Data([0x0A])
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: traceURL.path) {
            _ = FileManager.default.createFile(atPath: traceURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: traceURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}

nonisolated enum Phase1UITestFixtureConfigurationError: Error, Equatable, LocalizedError {
    case invalidArgument(String)
    case invalidPath(String)
    case missingDirectory(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let detail), .invalidPath(let detail):
            detail
        case .missingDirectory(let path):
            "Fixture directory is missing: \(path)"
        }
    }
}

nonisolated final class Phase1UITestFixtureAccessAdapter: SecurityScopedResourceAccessing {
    private let authorizedParent: URL
    private let lock = NSLock()
    private var parentIsActive = false

    init(authorizedParent: URL) {
        self.authorizedParent = authorizedParent.standardizedFileURL
    }

    func startAccessing(_ url: URL, owner: SecurityScopedAccessOwner) -> Bool {
        let normalizedURL = url.standardizedFileURL
        lock.lock()
        defer { lock.unlock() }

        if normalizedURL == authorizedParent {
            guard parentIsActive == false,
                  normalizedURL.startAccessingSecurityScopedResource() else {
                return false
            }
            parentIsActive = true
            return true
        }
        return parentIsActive && isDescendant(normalizedURL)
    }

    func stopAccessing(_ url: URL) throws {
        let normalizedURL = url.standardizedFileURL
        lock.lock()
        defer { lock.unlock() }

        if normalizedURL == authorizedParent {
            guard parentIsActive else {
                throw Phase1UITestFixtureConfigurationError.invalidPath(
                    "The fixture parent access is not active."
                )
            }
            normalizedURL.stopAccessingSecurityScopedResource()
            parentIsActive = false
            return
        }
        guard parentIsActive, isDescendant(normalizedURL) else {
            throw Phase1UITestFixtureConfigurationError.invalidPath(
                "The fixture lease is outside the authorized parent."
            )
        }
    }

    private func isDescendant(_ url: URL) -> Bool {
        let parentComponents = authorizedParent.pathComponents
        let components = url.pathComponents
        return components.count > parentComponents.count
            && Array(components.prefix(parentComponents.count)) == parentComponents
    }
}

nonisolated final class Phase1UITestFixtureStartupAccessStore: StartupAccessStoring {
    private let authorizedParent: URL

    init(authorizedParent: URL) {
        self.authorizedParent = authorizedParent.standardizedFileURL
    }

    func resolveAccess(to url: URL) throws -> StartupAccessBookmarkResolution? {
        let normalizedURL = url.standardizedFileURL
        guard isDescendant(normalizedURL) else { return nil }
        return StartupAccessBookmarkResolution(url: normalizedURL, isStale: false)
    }

    func saveAccess(to url: URL) throws {
        guard isDescendant(url.standardizedFileURL) else {
            throw Phase1UITestFixtureConfigurationError.invalidPath(
                "Fixture authorization cannot be saved outside its run parent."
            )
        }
    }

    private func isDescendant(_ url: URL) -> Bool {
        let parentComponents = authorizedParent.pathComponents
        let components = url.pathComponents
        return components.count > parentComponents.count
            && Array(components.prefix(parentComponents.count)) == parentComponents
    }
}
#endif
