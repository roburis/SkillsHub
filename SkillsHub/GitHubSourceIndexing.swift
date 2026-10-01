import CryptoKit
import Darwin
import Foundation
import zlib

nonisolated struct GitHubRepositoryIdentity: Equatable {
    var repositoryID: Int64? = nil
    var owner: String
    var repo: String

    var sourceName: String {
        "\(owner)/\(repo)"
    }
}

nonisolated struct GitHubRepositoryReference: Equatable {
    var repositoryID: Int64
    var owner: String
    var repo: String
    var branch: String
    var commitSHA: String

    var sourceName: String {
        "\(owner)/\(repo)"
    }
}

nonisolated enum GitHubSourceIssue: String, Codable, Error, Equatable {
    case networkFailure
    case rateLimited
    case treeTruncated
    case repositoryTooLarge
    case pathRestricted
    case unsupportedProvider
    case unsupportedVersion
    case invalidURL
    case repositoryChanged
    case branchUnavailable
    case timedOut
    case cancelled
    case archiveInvalid
    case contentMismatch
    case noSkills
}

nonisolated enum GitHubTreeEntryKind: String, Equatable {
    case tree
    case blob
    case gitlink
}

nonisolated struct GitHubTreeEntry: Equatable {
    var path: String
    var kind: GitHubTreeEntryKind
    var mode: String
    var objectID: String
    var byteCount: Int64?

    var isBlob: Bool { kind == .blob }

    init(path: String, kind: GitHubTreeEntryKind, mode: String, objectID: String, byteCount: Int64? = nil) {
        self.path = path
        self.kind = kind
        self.mode = mode
        self.objectID = objectID
        self.byteCount = byteCount
    }
}

nonisolated struct GitHubTreeSnapshot: Equatable {
    var entries: [GitHubTreeEntry]
    var isTruncated: Bool
}

nonisolated enum GitHubRepositoryRisk: String, Hashable {
    case gitlink
    case lfsPointer
}

nonisolated enum GitHubExternalDependencyKind: String, Equatable {
    case gitlink
    case lfsPointer
}

nonisolated struct GitHubExternalDependency: Equatable {
    var path: String
    var kind: GitHubExternalDependencyKind
    var objectID: String
}

nonisolated struct GitHubFetchMetrics: Equatable {
    var archiveByteCount: Int
    var expandedByteCount: Int64
    var nodeCount: Int
    var maximumDepth: Int
    var elapsed: TimeInterval
    var availableDiskByteCount: Int64?
    var peakResidentByteCount: Int64
}

nonisolated struct GitHubStagedRepository: Equatable {
    var directory: URL
    var manifest: ContentManifest
    var risks: [GitHubRepositoryRisk]
    var externalDependencies: [GitHubExternalDependency]
    var metrics: GitHubFetchMetrics
}

nonisolated struct GitHubIndexResult: Equatable {
    var source: SkillSource
    var availableSkills: [AvailableSkill]
    var issue: GitHubSourceIssue?
    var recoveryActions: [String]
    var stagedRepository: GitHubStagedRepository?
}

nonisolated protocol GitHubAPIClient {
    func resolve(_ identity: GitHubRepositoryIdentity, trackedBranch: String?) async throws -> GitHubRepositoryReference
    func tree(for repository: GitHubRepositoryReference) async throws -> GitHubTreeSnapshot
    func archive(for repository: GitHubRepositoryReference) async throws -> Data
    func blob(objectID: String, repository: GitHubRepositoryReference) async throws -> Data
}

nonisolated protocol GitHubSourceStaging {
    func stage(
        archive: Data,
        tree: GitHubTreeSnapshot,
        repository: GitHubRepositoryReference,
        blobLoader: (String) async throws -> Data
    ) async throws -> GitHubStagedRepository
    func discard(_ stagedRepository: GitHubStagedRepository) throws
}

nonisolated protocol HTTPDataClient {
    func data(for request: URLRequest, maximumByteCount: Int) async throws -> (Data, HTTPURLResponse)
}

nonisolated enum GitHubAPIClientFailure: Error, Equatable {
    case networkFailure
    case rateLimited(retryAfter: TimeInterval?)
    case repositoryTooLarge
    case pathRestricted
    case repositoryChanged
    case branchUnavailable
    case timedOut
    case cancelled
    case invalidArchive
    case contentMismatch
}

nonisolated final class URLSessionHTTPDataClient: HTTPDataClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest, maximumByteCount: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw GitHubAPIClientFailure.networkFailure
        }
        if response.expectedContentLength > Int64(maximumByteCount) {
            throw GitHubAPIClientFailure.repositoryTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maximumByteCount, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            if data.count == maximumByteCount {
                throw GitHubAPIClientFailure.repositoryTooLarge
            }
            data.append(byte)
        }
        return (data, response)
    }
}

nonisolated final class GitHubRESTAPIClient: GitHubAPIClient {
    private struct RepositoryResponse: Decodable {
        struct Owner: Decodable {
            var login: String
        }

        var id: Int64
        var name: String
        var owner: Owner
        var defaultBranch: String

        private enum CodingKeys: String, CodingKey {
            case id, name, owner
            case defaultBranch = "default_branch"
        }
    }

    private struct ReferenceResponse: Decodable {
        struct Object: Decodable {
            var type: String
            var sha: String
        }

        var ref: String
        var object: Object
    }

    private struct TreeResponse: Decodable {
        struct Entry: Decodable {
            var path: String
            var mode: String
            var type: String
            var sha: String
            var size: Int64?
        }

        var tree: [Entry]
        var truncated: Bool
    }

    private struct BlobResponse: Decodable {
        var sha: String
        var encoding: String
        var content: String
    }

    private let httpClient: HTTPDataClient
    private let apiBaseURL: URL
    private let decoder: JSONDecoder
    private let requestTimeout: TimeInterval
    private let maximumJSONByteCount: Int
    private let maximumArchiveByteCount: Int
    private let maximumBlobByteCount: Int

    init(
        httpClient: HTTPDataClient = URLSessionHTTPDataClient(),
        apiBaseURL: URL = URL(string: "https://api.github.com")!,
        requestTimeout: TimeInterval = 30,
        maximumJSONByteCount: Int = 32 * 1_024 * 1_024,
        maximumArchiveByteCount: Int = 128 * 1_024 * 1_024,
        maximumBlobByteCount: Int = 32 * 1_024 * 1_024
    ) {
        self.httpClient = httpClient
        self.apiBaseURL = apiBaseURL
        self.decoder = JSONDecoder()
        self.requestTimeout = requestTimeout
        self.maximumJSONByteCount = maximumJSONByteCount
        self.maximumArchiveByteCount = maximumArchiveByteCount
        self.maximumBlobByteCount = maximumBlobByteCount
    }

    func resolve(_ identity: GitHubRepositoryIdentity, trackedBranch: String?) async throws -> GitHubRepositoryReference {
        guard (identity.repositoryID == nil) == (trackedBranch == nil) else {
            throw GitHubAPIClientFailure.repositoryChanged
        }
        let url = repositoryURL(for: identity)
        let (data, response) = try await perform(request(url: url), maximumByteCount: maximumJSONByteCount)
        try validate(response, missingBranch: false)
        let repository = try decoder.decode(RepositoryResponse.self, from: data)
        if let repositoryID = identity.repositoryID {
            guard repositoryID == repository.id else {
                throw GitHubAPIClientFailure.repositoryChanged
            }
        }
        let branch = trackedBranch ?? repository.defaultBranch

        let canonicalIdentity = GitHubRepositoryIdentity(repositoryID: repository.id, owner: repository.owner.login, repo: repository.name)
        guard canonicalIdentity.sourceName.caseInsensitiveCompare(identity.sourceName) == .orderedSame,
              !branch.isEmpty else {
            throw GitHubAPIClientFailure.pathRestricted
        }

        let refURL = repositoryURL(for: canonicalIdentity)
            .appendingPathComponent("git")
            .appendingPathComponent("ref")
            .appendingPathComponent("heads")
            .appendingPathComponent(branch)
        let (refData, refResponse) = try await perform(request(url: refURL), maximumByteCount: maximumJSONByteCount)
        try validate(refResponse, missingBranch: true)
        let reference = try decoder.decode(ReferenceResponse.self, from: refData)
        guard reference.ref == "refs/heads/\(branch)",
              reference.object.type == "commit",
              Self.isCommitSHA(reference.object.sha) else {
            throw GitHubAPIClientFailure.networkFailure
        }

        return GitHubRepositoryReference(
            repositoryID: repository.id,
            owner: canonicalIdentity.owner,
            repo: canonicalIdentity.repo,
            branch: branch,
            commitSHA: reference.object.sha.lowercased()
        )
    }

    func tree(for repository: GitHubRepositoryReference) async throws -> GitHubTreeSnapshot {
        let url = apiBaseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repository.owner)
            .appendingPathComponent(repository.repo)
            .appendingPathComponent("git")
            .appendingPathComponent("trees")
            .appendingPathComponent(repository.commitSHA)
            .appending(queryItems: [URLQueryItem(name: "recursive", value: "1")])
        let (data, response) = try await perform(request(url: url), maximumByteCount: maximumJSONByteCount)
        try validate(response, missingBranch: false)
        let payload = try decoder.decode(TreeResponse.self, from: data)
        return GitHubTreeSnapshot(
            entries: try payload.tree.map { entry in
                let kind: GitHubTreeEntryKind
                switch entry.type {
                case "tree": kind = .tree
                case "blob": kind = .blob
                case "commit": kind = .gitlink
                default: throw GitHubAPIClientFailure.contentMismatch
                }
                return GitHubTreeEntry(
                    path: entry.path,
                    kind: kind,
                    mode: entry.mode,
                    objectID: entry.sha.lowercased(),
                    byteCount: entry.size
                )
            },
            isTruncated: payload.truncated
        )
    }

    func archive(for repository: GitHubRepositoryReference) async throws -> Data {
        let url = repositoryURL(for: GitHubRepositoryIdentity(
            repositoryID: repository.repositoryID,
            owner: repository.owner,
            repo: repository.repo
        ))
            .appendingPathComponent("tarball")
            .appendingPathComponent(repository.commitSHA)
        let (data, response) = try await perform(request(url: url), maximumByteCount: maximumArchiveByteCount)
        try validate(response, missingBranch: false)
        return data
    }

    func blob(objectID: String, repository: GitHubRepositoryReference) async throws -> Data {
        guard Self.isCommitSHA(objectID) else {
            throw GitHubAPIClientFailure.contentMismatch
        }
        let url = repositoryURL(for: GitHubRepositoryIdentity(
            repositoryID: repository.repositoryID,
            owner: repository.owner,
            repo: repository.repo
        ))
            .appendingPathComponent("git")
            .appendingPathComponent("blobs")
            .appendingPathComponent(objectID)
        let (data, response) = try await perform(request(url: url), maximumByteCount: maximumBlobByteCount * 2)
        try validate(response, missingBranch: false)
        let payload = try decoder.decode(BlobResponse.self, from: data)
        guard payload.sha.caseInsensitiveCompare(objectID) == .orderedSame,
              payload.encoding == "base64",
              let decoded = Data(base64Encoded: payload.content.filter { !$0.isWhitespace }),
              decoded.count <= maximumBlobByteCount else {
            throw GitHubAPIClientFailure.contentMismatch
        }
        return decoded
    }

    private func repositoryURL(for identity: GitHubRepositoryIdentity) -> URL {
        apiBaseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(identity.owner)
            .appendingPathComponent(identity.repo)
    }

    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = requestTimeout
        return request
    }

    private func perform(_ request: URLRequest, maximumByteCount: Int) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await httpClient.data(for: request, maximumByteCount: maximumByteCount)
        } catch is CancellationError {
            throw GitHubAPIClientFailure.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw GitHubAPIClientFailure.cancelled
        } catch let error as URLError where error.code == .timedOut {
            throw GitHubAPIClientFailure.timedOut
        } catch let failure as GitHubAPIClientFailure {
            throw failure
        } catch {
            throw GitHubAPIClientFailure.networkFailure
        }
    }

    private func validate(_ response: HTTPURLResponse, missingBranch: Bool) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 403 where response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0", 429:
            throw GitHubAPIClientFailure.rateLimited(retryAfter: retryDelay(from: response))
        case 413:
            throw GitHubAPIClientFailure.repositoryTooLarge
        case 404 where missingBranch:
            throw GitHubAPIClientFailure.branchUnavailable
        case 401, 403, 404:
            throw GitHubAPIClientFailure.pathRestricted
        default:
            throw GitHubAPIClientFailure.networkFailure
        }
    }

    private func retryDelay(from response: HTTPURLResponse) -> TimeInterval? {
        if let value = response.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(value) {
            return max(0, seconds)
        }
        if let value = response.value(forHTTPHeaderField: "X-RateLimit-Reset"), let reset = TimeInterval(value) {
            return max(0, reset - Date().timeIntervalSince1970)
        }
        return nil
    }

    private static func isCommitSHA(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
    }
}

nonisolated final class FileSystemGitHubSourceStager: GitHubSourceStaging {
    private enum ArchiveNodeKind {
        case directory
        case file(Data)
        case symbolicLink(String)

        var isContent: Bool {
            switch self { case .file, .symbolicLink: true; case .directory: false }
        }

        var isSymbolicLink: Bool {
            if case .symbolicLink = self { return true }
            return false
        }
    }

    private struct ArchiveNode {
        var path: String
        var kind: ArchiveNodeKind
        var isExecutable: Bool
    }

    private let stagingRoot: URL
    private let fileManager: FileManager
    private let maximumExpandedByteCount: Int64
    private let maximumNodeCount: Int
    private let maximumDepth: Int
    private let maximumElapsed: TimeInterval
    private let availableCapacity: (URL) -> Int64?

    init(
        stagingRoot: URL,
        fileManager: FileManager = .default,
        maximumExpandedByteCount: Int64 = 512 * 1_024 * 1_024,
        maximumNodeCount: Int = 100_000,
        maximumDepth: Int = 64,
        maximumElapsed: TimeInterval = 30,
        availableCapacity: ((URL) -> Int64?)? = nil
    ) {
        self.stagingRoot = stagingRoot
        self.fileManager = fileManager
        self.maximumExpandedByteCount = maximumExpandedByteCount
        self.maximumNodeCount = maximumNodeCount
        self.maximumDepth = maximumDepth
        self.maximumElapsed = maximumElapsed
        self.availableCapacity = availableCapacity ?? { url in
            try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        }
    }

    func stage(
        archive: Data,
        tree: GitHubTreeSnapshot,
        repository: GitHubRepositoryReference,
        blobLoader: (String) async throws -> Data
    ) async throws -> GitHubStagedRepository {
        let startedAt = Date()
        guard !tree.isTruncated else { throw GitHubAPIClientFailure.repositoryTooLarge }
        var nodes = try parseTar(try gunzip(archive, startedAt: startedAt), startedAt: startedAt)
        try validatePaths(nodes.map(\.path))
        try validatePaths(tree.entries.map(\.path))

        var risks = Set<GitHubRepositoryRisk>()
        var externalDependencies: [GitHubExternalDependency] = []
        let treeByPath = Dictionary(uniqueKeysWithValues: tree.entries.map { ($0.path, $0) })
        try validateTreeEntries(tree.entries)
        for node in nodes {
            if node.kind.isContent {
                guard treeByPath[node.path]?.kind == .blob else { throw GitHubAPIClientFailure.contentMismatch }
            } else {
                let isTreePath = treeByPath[node.path]?.kind == .tree
                let isImpliedTreePath = tree.entries.contains { $0.path.hasPrefix(node.path + "/") }
                guard isTreePath || isImpliedTreePath else { throw GitHubAPIClientFailure.contentMismatch }
            }
        }

        let symbolicLinkPaths = nodes.compactMap { $0.kind.isSymbolicLink ? $0.path : nil }
        guard !nodes.contains(where: { node in
            symbolicLinkPaths.contains { node.path.hasPrefix($0 + "/") }
        }) else {
            throw GitHubAPIClientFailure.contentMismatch
        }

        for entry in tree.entries {
            try checkBudget(startedAt: startedAt)
            switch entry.kind {
            case .tree:
                if nodes.first(where: { $0.path == entry.path }) == nil {
                    nodes.append(ArchiveNode(path: entry.path, kind: .directory, isExecutable: false))
                }
            case .gitlink:
                risks.insert(.gitlink)
                externalDependencies.append(GitHubExternalDependency(path: entry.path, kind: .gitlink, objectID: entry.objectID))
                guard !nodes.contains(where: { $0.path == entry.path && $0.kind.isContent }) &&
                        !nodes.contains(where: { $0.path.hasPrefix(entry.path + "/") && $0.kind.isContent }) else {
                    throw GitHubAPIClientFailure.contentMismatch
                }
                nodes.append(ArchiveNode(path: entry.path, kind: .directory, isExecutable: false))
            case .blob:
                let nodeIndex = nodes.firstIndex(where: { $0.path == entry.path })
                var node = nodeIndex.map { nodes[$0] }
                if node == nil {
                    let data = try await blobLoader(entry.objectID)
                    node = try nodeFromBlob(data, entry: entry)
                    nodes.append(node!)
                }
                try validate(node: node!, against: entry)
                if case .file(let data) = node!.kind, isLFSPointer(data) {
                    risks.insert(.lfsPointer)
                    externalDependencies.append(GitHubExternalDependency(path: entry.path, kind: .lfsPointer, objectID: entry.objectID))
                }
            }
        }

        let expandedByteCount = nodes.reduce(Int64(0)) { total, node in
            switch node.kind {
            case .file(let data): return total + Int64(data.count)
            case .symbolicLink(let target): return total + Int64(target.utf8.count)
            case .directory: return total
            }
        }
        guard nodes.count <= maximumNodeCount, expandedByteCount <= maximumExpandedByteCount else {
            throw GitHubAPIClientFailure.repositoryTooLarge
        }
        let availableBeforeWrite = availableCapacity(stagingRoot)
        if let availableBeforeWrite,
           availableBeforeWrite < expandedByteCount + Int64(archive.count) {
            throw GitHubAPIClientFailure.repositoryTooLarge
        }

        let repositoryRoot = stagingRoot
            .appendingPathComponent(repository.owner, isDirectory: true)
            .appendingPathComponent(".\(repository.repo)-\(repository.commitSHA)-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: repositoryRoot, withIntermediateDirectories: true)
            try write(nodes: nodes, to: repositoryRoot, startedAt: startedAt)
            let manifest = try ContentManifestBuilder(fileManager: fileManager).build(
                for: repositoryRoot,
                authorizedRoot: repositoryRoot
            )
            try checkBudget(startedAt: startedAt)
            let availableDisk = availableCapacity(repositoryRoot)
            return GitHubStagedRepository(
                directory: repositoryRoot,
                manifest: manifest,
                risks: risks.sorted { $0.rawValue < $1.rawValue },
                externalDependencies: externalDependencies.sorted { $0.path < $1.path },
                metrics: GitHubFetchMetrics(
                    archiveByteCount: archive.count,
                    expandedByteCount: expandedByteCount,
                    nodeCount: nodes.count,
                    maximumDepth: nodes.map { $0.path.split(separator: "/").count }.max() ?? 0,
                    elapsed: Date().timeIntervalSince(startedAt),
                    availableDiskByteCount: availableDisk,
                    peakResidentByteCount: peakResidentByteCount()
                )
            )
        } catch {
            do {
                try removeRepositoryAndEmptyOwner(at: repositoryRoot)
            } catch {
                throw GitHubAPIClientFailure.invalidArchive
            }
            throw error
        }
    }

    func discard(_ stagedRepository: GitHubStagedRepository) throws {
        do {
            try removeRepositoryAndEmptyOwner(at: stagedRepository.directory)
        } catch {
            throw GitHubAPIClientFailure.invalidArchive
        }
    }

    private func removeRepositoryAndEmptyOwner(at repositoryRoot: URL) throws {
        if fileManager.fileExists(atPath: repositoryRoot.path) {
            try fileManager.removeItem(at: repositoryRoot)
        }
        let ownerRoot = repositoryRoot.deletingLastPathComponent()
        if fileManager.fileExists(atPath: ownerRoot.path),
           try fileManager.contentsOfDirectory(atPath: ownerRoot.path).isEmpty {
            try fileManager.removeItem(at: ownerRoot)
        }
    }

    private func validate(node: ArchiveNode, against entry: GitHubTreeEntry) throws {
        let bytes: Data
        switch (entry.mode, node.kind) {
        case ("120000", .symbolicLink(let target)):
            guard isSafeLink(target, at: entry.path) else { throw GitHubAPIClientFailure.contentMismatch }
            bytes = Data(target.utf8)
        case (let mode, .file(let data)) where mode == "100644" || mode == "100755":
            guard node.isExecutable == (mode == "100755") else { throw GitHubAPIClientFailure.contentMismatch }
            bytes = data
        default:
            throw GitHubAPIClientFailure.contentMismatch
        }
        guard gitBlobID(bytes, matching: entry.objectID).caseInsensitiveCompare(entry.objectID) == .orderedSame,
              entry.byteCount == nil || entry.byteCount == Int64(bytes.count) else {
            throw GitHubAPIClientFailure.contentMismatch
        }
    }

    private func validateTreeEntries(_ entries: [GitHubTreeEntry]) throws {
        for entry in entries {
            guard (entry.objectID.count == 40 || entry.objectID.count == 64),
                  entry.objectID.allSatisfy(\.isHexDigit) else {
                throw GitHubAPIClientFailure.contentMismatch
            }
            switch entry.kind {
            case .tree where entry.mode == "040000": continue
            case .gitlink where entry.mode == "160000": continue
            case .blob where entry.mode == "100644" || entry.mode == "100755" || entry.mode == "120000": continue
            default: throw GitHubAPIClientFailure.contentMismatch
            }
        }
    }

    private func nodeFromBlob(_ data: Data, entry: GitHubTreeEntry) throws -> ArchiveNode {
        guard gitBlobID(data, matching: entry.objectID).caseInsensitiveCompare(entry.objectID) == .orderedSame else {
            throw GitHubAPIClientFailure.contentMismatch
        }
        if entry.mode == "120000" {
            guard let target = String(data: data, encoding: .utf8), isSafeLink(target, at: entry.path) else {
                throw GitHubAPIClientFailure.contentMismatch
            }
            return ArchiveNode(path: entry.path, kind: .symbolicLink(target), isExecutable: false)
        }
        guard entry.mode == "100644" || entry.mode == "100755" else {
            throw GitHubAPIClientFailure.contentMismatch
        }
        return ArchiveNode(path: entry.path, kind: .file(data), isExecutable: entry.mode == "100755")
    }

    private func write(nodes: [ArchiveNode], to root: URL, startedAt: Date) throws {
        for node in nodes.sorted(by: { $0.path.count < $1.path.count }) where !node.kind.isSymbolicLink {
            try checkBudget(startedAt: startedAt)
            let destination = node.path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
            switch node.kind {
            case .directory:
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            case .file(let data):
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                if node.isExecutable { try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path) }
            case .symbolicLink:
                break
            }
        }
        for node in nodes where node.kind.isSymbolicLink {
            try checkBudget(startedAt: startedAt)
            guard case .symbolicLink(let target) = node.kind else { continue }
            let destination = node.path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        }
    }

    private func validatePaths(_ paths: [String]) throws {
        var normalized = Set<String>()
        for path in paths {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !components.isEmpty,
                  components.count <= maximumDepth,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw GitHubAPIClientFailure.contentMismatch
            }
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard normalized.insert(key).inserted else { throw GitHubAPIClientFailure.contentMismatch }
        }
    }

    private func isSafeLink(_ target: String, at path: String) -> Bool {
        guard !target.hasPrefix("/"), !target.isEmpty else { return false }
        var depth = path.split(separator: "/").count - 1
        for component in target.split(separator: "/", omittingEmptySubsequences: false) {
            if component == ".." { depth -= 1 }
            else if component != "." && !component.isEmpty { depth += 1 }
            if depth < 0 { return false }
        }
        return true
    }

    private func gitBlobID(_ data: Data, matching objectID: String) -> String {
        var object = Data("blob \(data.count)\0".utf8)
        object.append(data)
        if objectID.count == 64 {
            return SHA256.hash(data: object).map { String(format: "%02x", $0) }.joined()
        }
        return Insecure.SHA1.hash(data: object).map { String(format: "%02x", $0) }.joined()
    }

    private func isLFSPointer(_ data: Data) -> Bool {
        data.starts(with: Data("version https://git-lfs.github.com/spec/v1\n".utf8))
    }

    private func checkBudget(startedAt: Date) throws {
        if Task.isCancelled { throw GitHubAPIClientFailure.cancelled }
        if Date().timeIntervalSince(startedAt) > maximumElapsed { throw GitHubAPIClientFailure.timedOut }
    }

    private func gunzip(_ data: Data, startedAt: Date) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw GitHubAPIClientFailure.invalidArchive
        }
        defer { inflateEnd(&stream) }
        var output = Data()
        var exceededBudget = false
        var cancelled = false
        var timedOut = false
        let result = data.withUnsafeBytes { source -> Int32 in
            guard let sourceAddress = source.bindMemory(to: Bytef.self).baseAddress else { return Z_DATA_ERROR }
            stream.next_in = UnsafeMutablePointer(mutating: sourceAddress)
            stream.avail_in = uInt(source.count)
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            var status = Int32(Z_OK)
            while status == Z_OK {
                if Task.isCancelled {
                    cancelled = true
                    return Z_BUF_ERROR
                }
                if Date().timeIntervalSince(startedAt) > maximumElapsed {
                    timedOut = true
                    return Z_BUF_ERROR
                }
                status = buffer.withUnsafeMutableBytes { destination in
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = buffer.count - Int(stream.avail_out)
                output.append(contentsOf: buffer.prefix(produced))
                if output.count > maximumExpandedByteCount {
                    exceededBudget = true
                    return Z_MEM_ERROR
                }
            }
            return status
        }
        if cancelled { throw GitHubAPIClientFailure.cancelled }
        if timedOut { throw GitHubAPIClientFailure.timedOut }
        if exceededBudget { throw GitHubAPIClientFailure.repositoryTooLarge }
        guard result == Z_STREAM_END else { throw GitHubAPIClientFailure.invalidArchive }
        return output
    }

    private func parseTar(_ data: Data, startedAt: Date) throws -> [ArchiveNode] {
        var offset = 0
        var rawNodes: [ArchiveNode] = []
        var paxPath: String?
        var paxLink: String?
        var longPath: String?
        var longLink: String?
        var foundTerminator = false
        while offset + 512 <= data.count {
            try checkBudget(startedAt: startedAt)
            guard rawNodes.count < maximumNodeCount else { throw GitHubAPIClientFailure.repositoryTooLarge }
            let header = data.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) {
                guard offset + 1_024 <= data.count,
                      data[(offset + 512)..<(offset + 1_024)].allSatisfy({ $0 == 0 }) else {
                    throw GitHubAPIClientFailure.invalidArchive
                }
                foundTerminator = true
                break
            }
            guard validTarChecksum(header),
                  let size = tarNumber(header, 124..<136),
                  let mode = tarNumber(header, 100..<108),
                  size <= UInt64(maximumExpandedByteCount) else {
                throw GitHubAPIClientFailure.invalidArchive
            }
            let bodyStart = offset + 512
            let bodyEnd = bodyStart + Int(size)
            guard bodyEnd <= data.count else { throw GitHubAPIClientFailure.invalidArchive }
            let body = data.subdata(in: bodyStart..<bodyEnd)
            let type = header[156]
            let headerPath = [tarString(header, 345..<500), tarString(header, 0..<100)]
                .filter { !$0.isEmpty }.joined(separator: "/")
            let path = paxPath ?? longPath ?? headerPath
            let link = paxLink ?? longLink ?? tarString(header, 157..<257)
            paxPath = nil; paxLink = nil; longPath = nil; longLink = nil

            switch type {
            case 0, 48:
                rawNodes.append(ArchiveNode(path: path, kind: .file(body), isExecutable: mode & 0o111 != 0))
            case 50:
                rawNodes.append(ArchiveNode(path: path, kind: .symbolicLink(link), isExecutable: false))
            case 53:
                rawNodes.append(ArchiveNode(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), kind: .directory, isExecutable: false))
            case 103:
                let values = try parsePAX(body)
                // ponytail: only GitHub's global comment; support attribute semantics before allowing other keys.
                guard values.keys.allSatisfy({ $0 == "comment" }) else {
                    throw GitHubAPIClientFailure.invalidArchive
                }
            case 120:
                let values = try parsePAX(body)
                paxPath = values["path"]
                paxLink = values["linkpath"]
            case 76:
                longPath = tarCString(body)
            case 75:
                longLink = tarCString(body)
            default:
                throw GitHubAPIClientFailure.invalidArchive
            }
            offset = bodyStart + ((Int(size) + 511) / 512) * 512
        }
        guard foundTerminator,
              let root = rawNodes.compactMap({ $0.path.split(separator: "/").first.map(String.init) }).first,
              rawNodes.first?.path == root,
              rawNodes.first.map({ if case .directory = $0.kind { true } else { false } }) == true,
              rawNodes.allSatisfy({ $0.path == root || $0.path.hasPrefix(root + "/") }) else {
            throw GitHubAPIClientFailure.invalidArchive
        }
        return rawNodes.compactMap { node in
            guard node.path != root else { return nil }
            var result = node
            result.path = String(node.path.dropFirst(root.count + 1))
            return result
        }
    }

    private func validTarChecksum(_ header: Data) -> Bool {
        guard let expected = tarNumber(header, 148..<156) else { return false }
        let actual = header.enumerated().reduce(UInt64(0)) { total, item in
            total + UInt64((148..<156).contains(item.offset) ? 32 : item.element)
        }
        return expected == actual
    }

    private func tarNumber(_ data: Data, _ range: Range<Int>) -> UInt64? {
        let value = tarString(data, range).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? 0 : UInt64(value, radix: 8)
    }

    private func tarString(_ data: Data, _ range: Range<Int>) -> String {
        tarCString(data.subdata(in: range))
    }

    private func tarCString(_ data: Data) -> String {
        String(decoding: data.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    private func parsePAX(_ data: Data) throws -> [String: String] {
        var result: [String: String] = [:]
        var offset = 0
        while offset < data.count {
            guard let space = data[offset...].firstIndex(of: 32),
                  let length = Int(String(decoding: data[offset..<space], as: UTF8.self)),
                  length > space - offset + 2,
                  offset + length <= data.count,
                  data[offset + length - 1] == 10 else {
                throw GitHubAPIClientFailure.invalidArchive
            }
            let record = String(decoding: data[(space + 1)..<(offset + length - 1)], as: UTF8.self)
            let pair = record.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard pair.count == 2, !pair[0].isEmpty,
                  result.updateValue(pair[1], forKey: pair[0]) == nil else {
                throw GitHubAPIClientFailure.invalidArchive
            }
            offset += length
        }
        return result
    }

    private func peakResidentByteCount() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int64(usage.ru_maxrss)
    }
}

nonisolated struct GitHubRepositoryParser {
    func parse(_ rawValue: String) throws -> GitHubRepositoryIdentity {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL?
        if value.hasPrefix("https://") {
            url = URL(string: value)
        } else if value.contains("://") {
            throw GitHubSourceIssue.unsupportedProvider
        } else {
            url = URL(string: "https://github.com/\(value)")
        }

        guard let url,
              url.scheme == "https",
              url.host?.lowercased() == "github.com",
              url.user == nil,
              url.password == nil,
              url.port == nil else {
            throw GitHubSourceIssue.unsupportedProvider
        }

        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2, url.query == nil, url.fragment == nil else {
            throw GitHubSourceIssue.invalidURL
        }
        guard components.count == 2 else {
            throw GitHubSourceIssue.unsupportedVersion
        }

        let owner = components[0]
        let repo = components[1].hasSuffix(".git") ? String(components[1].dropLast(4)) : components[1]
        guard isSafePathSegment(owner), isSafePathSegment(repo) else {
            throw GitHubSourceIssue.invalidURL
        }
        return GitHubRepositoryIdentity(repositoryID: nil, owner: owner, repo: repo)
    }

    private func isSafePathSegment(_ segment: String) -> Bool {
        guard !segment.isEmpty, segment != ".", segment != ".." else {
            return false
        }
        return segment.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
        }
    }

}

nonisolated final class GitHubSourceIndexer {
    private let apiClient: GitHubAPIClient
    private let stager: GitHubSourceStaging
    private let parser: GitHubRepositoryParser
    private let localIndexer: LocalSourceIndexer

    init(
        apiClient: GitHubAPIClient,
        stager: GitHubSourceStaging,
        parser: GitHubRepositoryParser = GitHubRepositoryParser(),
        localIndexer: LocalSourceIndexer = LocalSourceIndexer()
    ) {
        self.apiClient = apiClient
        self.stager = stager
        self.parser = parser
        self.localIndexer = localIndexer
    }

    func index(
        rawURL: String,
        trackedBranch: String? = nil,
        repositoryID: Int64? = nil,
        sourceID: UUID = UUID()
    ) async -> GitHubIndexResult {
        do {
            var identity = try parser.parse(rawURL)
            identity.repositoryID = repositoryID
            let repository = try await apiClient.resolve(identity, trackedBranch: trackedBranch)
            var source = SkillSource(
                id: sourceID,
                kind: .githubRepository,
                name: repository.sourceName,
                urlString: "https://github.com/\(repository.owner)/\(repository.repo)",
                githubRepositoryID: repository.repositoryID,
                ref: repository.branch,
                resolvedVersion: repository.commitSHA
            )

            let tree = try await apiClient.tree(for: repository)
            guard !tree.isTruncated else { throw GitHubSourceIssue.treeTruncated }
            let archive = try await apiClient.archive(for: repository)
            let staged = try await stager.stage(
                archive: archive,
                tree: tree,
                repository: repository,
                blobLoader: { [apiClient] objectID in
                    try await apiClient.blob(objectID: objectID, repository: repository)
                }
            )
            let localIndex = localIndexer.index(directory: staged.directory, sourceID: sourceID)
            guard !localIndex.source.isIndexIncomplete else {
                try stager.discard(staged)
                throw GitHubSourceIssue.archiveInvalid
            }
            guard !localIndex.availableSkills.isEmpty else {
                try stager.discard(staged)
                throw GitHubSourceIssue.noSkills
            }
            source.sourceMode = sourceMode(for: localIndex.availableSkills)
            source.localPath = staged.directory.path
            source.contentFingerprint = localIndex.source.contentFingerprint
            source.directoryIdentity = localIndex.source.directoryIdentity
            source.lastCheckedAt = localIndex.source.lastCheckedAt

            return GitHubIndexResult(
                source: source,
                availableSkills: localIndex.availableSkills,
                issue: nil,
                recoveryActions: [],
                stagedRepository: staged
            )
        } catch let issue as GitHubSourceIssue {
            return incompleteSource(rawURL: rawURL, issue: issue, sourceID: sourceID)
        } catch let failure as GitHubAPIClientFailure {
            return incompleteSource(rawURL: rawURL, issue: issue(for: failure), sourceID: sourceID)
        } catch {
            return incompleteSource(rawURL: rawURL, issue: .networkFailure, sourceID: sourceID)
        }
    }

    private func incompleteSource(rawURL: String, issue: GitHubSourceIssue, sourceID: UUID = UUID()) -> GitHubIndexResult {
        let name: String
        let urlString: String?
        if let repository = try? parser.parse(rawURL) {
            name = repository.sourceName
            urlString = "https://github.com/\(repository.owner)/\(repository.repo)"
        } else {
            name = rawURL
            urlString = rawURL
        }

        let source = SkillSource(
            id: sourceID,
            kind: .githubRepository,
            name: name,
            urlString: urlString,
            sourceMode: .unknown,
            isIndexIncomplete: true,
            indexStatusReason: issue.rawValue
        )
        return GitHubIndexResult(source: source, availableSkills: [], issue: issue, recoveryActions: recoveryActions(for: issue), stagedRepository: nil)
    }

    private func issue(for failure: GitHubAPIClientFailure) -> GitHubSourceIssue {
        switch failure {
        case .networkFailure:
            return .networkFailure
        case .rateLimited:
            return .rateLimited
        case .repositoryTooLarge:
            return .repositoryTooLarge
        case .pathRestricted:
            return .pathRestricted
        case .repositoryChanged:
            return .repositoryChanged
        case .branchUnavailable:
            return .branchUnavailable
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        case .invalidArchive:
            return .archiveInvalid
        case .contentMismatch:
            return .contentMismatch
        }
    }

    private func sourceMode(for skills: [AvailableSkill]) -> GitHubSourceMode {
        let hasRootSkill = skills.contains { $0.skillPath == "." }
        if hasRootSkill && skills.count == 1 { return .single }
        if hasRootSkill { return .mixed }
        return .collection
    }

    private func recoveryActions(for issue: GitHubSourceIssue?) -> [String] {
        guard issue != nil else {
            return []
        }
        return issue == .cancelled ? [] : ["retry"]
    }

}
