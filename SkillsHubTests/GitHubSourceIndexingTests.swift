import CryptoKit
import Foundation
import Testing
import zlib
@testable import SkillsHub

struct GitHubSourceIndexingTests {
    @Test func completeArchiveMatchesTreeAndUsesLocalDiscovery() async throws {
        let fixture = repositoryFixture()
        let stagingRoot = try temporaryDirectory()
        let api = MockGitHubAPIClient(treeResult: fixture.tree, archiveData: try tarGzip(fixture.archiveEntries))
        let result = await GitHubSourceIndexer(
            apiClient: api,
            stager: FileSystemGitHubSourceStager(stagingRoot: stagingRoot)
        ).index(rawURL: "https://github.com/fixture-owner/lifecycle")

        let staged = try #require(result.stagedRepository)
        #expect(result.issue == nil)
        #expect(result.source.resolvedVersion == commitA)
        #expect(result.source.sourceMode == .mixed)
        #expect(result.availableSkills.map(\.skillPath) == [".", ".hidden/deep", "skills/keep", "skills/move", "skills/remove"])
        #expect(staged.manifest.entries.contains { $0.relativePath == "scripts/helper.sh" && $0.isExecutable })
        #expect(staged.manifest.entries.contains {
            $0.relativePath == "skills/keep/config-link" &&
                $0.kind == .symbolicLink &&
                $0.symbolicLinkTarget == "../../shared/config.json"
        })
        #expect(try Data(contentsOf: staged.directory.appendingPathComponent("assets/icon.bin")) == Data([0, 255, 1, 2]))
        #expect(staged.metrics.archiveByteCount > 0)
        #expect(staged.metrics.expandedByteCount == fixture.expandedByteCount)
        #expect(staged.metrics.maximumDepth == 3)
        #expect(staged.risks.isEmpty)
        #expect(staged.externalDependencies.isEmpty)
        #expect(api.requestedReferences.allSatisfy { $0.commitSHA == commitA })

        let fixtureB = repositoryFixtureB()
        let apiB = MockGitHubAPIClient(
            treeResult: fixtureB.tree,
            archiveData: try tarGzip(fixtureB.archiveEntries, commitSHA: commitB),
            commitSHA: commitB
        )
        let resultB = await GitHubSourceIndexer(
            apiClient: apiB,
            stager: FileSystemGitHubSourceStager(stagingRoot: stagingRoot)
        ).index(rawURL: "https://github.com/fixture-owner/lifecycle")
        #expect(resultB.availableSkills.map(\.skillPath) == [".", ".hidden/deep", "skills/keep", "skills/moved", "skills/new"])
        #expect(resultB.stagedRepository?.manifest.digest != staged.manifest.digest)
        #expect(apiB.requestedReferences.allSatisfy { $0.commitSHA == commitB })
    }

    @Test(arguments: ["999 comment=broken\n", "5 ab\n", "18 path=../escape\n", "10 size=0\n"])
    func malformedOrStructuralGlobalPAXIsRejected(metadata: String) async throws {
        let fixture = repositoryFixture()
        let result = await GitHubSourceIndexer(
            apiClient: MockGitHubAPIClient(
                treeResult: fixture.tree,
                archiveData: try tarGzip(fixture.archiveEntries, globalPAX: Data(metadata.utf8))
            ),
            stager: FileSystemGitHubSourceStager(stagingRoot: try temporaryDirectory())
        ).index(rawURL: "fixture-owner/lifecycle")

        #expect(result.issue == .archiveInvalid)
        #expect(result.stagedRepository == nil)
    }

    @Test func archiveOmissionIsFilledOnlyFromSameCommitBlob() async throws {
        var fixture = repositoryFixture()
        let omittedPath = "shared/config.json"
        let omitted = try #require(fixture.archiveEntries.first { $0.path == omittedPath })
        fixture.archiveEntries.removeAll { $0.path == omittedPath }
        guard case .file(let bytes) = omitted.kind else { Issue.record("Expected file fixture"); return }
        let objectID = gitBlobID(bytes)
        let api = MockGitHubAPIClient(
            treeResult: fixture.tree,
            archiveData: try tarGzip(fixture.archiveEntries),
            blobs: [objectID: bytes]
        )
        let result = await GitHubSourceIndexer(
            apiClient: api,
            stager: FileSystemGitHubSourceStager(stagingRoot: try temporaryDirectory())
        ).index(rawURL: "fixture-owner/lifecycle")

        let staged = try #require(result.stagedRepository)
        #expect(try Data(contentsOf: staged.directory.appendingPathComponent(omittedPath)) == bytes)
        #expect(api.requestedBlobIDs == [objectID])
        #expect(api.requestedReferences.allSatisfy { $0.commitSHA == commitA })
    }

    @Test func sha256GitBlobIDsUseTheRepositoryObjectFormat() async throws {
        let skill = Data(skillText(name: "SHA256", description: "SHA-256 repository skill.").utf8)
        let tree = GitHubTreeSnapshot(entries: [
            GitHubTreeEntry(path: "SKILL.md", kind: .blob, mode: "100644", objectID: gitBlobID(skill, sha256: true), byteCount: Int64(skill.count))
        ], isTruncated: false)
        let result = await GitHubSourceIndexer(
            apiClient: MockGitHubAPIClient(
                treeResult: tree,
                archiveData: try tarGzip([TarFixtureEntry(path: "SKILL.md", kind: .file(skill), mode: 0o644)])
            ),
            stager: FileSystemGitHubSourceStager(stagingRoot: try temporaryDirectory())
        ).index(rawURL: "fixture-owner/lifecycle")

        #expect(result.issue == nil)
        #expect(result.stagedRepository != nil)
    }

    @Test func mismatchAndUnsafeArchiveNeverReplaceExistingContent() async throws {
        let cases: [(String, (inout RepositoryFixture) -> Void)] = [
            ("blob", { fixture in
                fixture.archiveEntries = fixture.archiveEntries.map {
                    $0.path == "shared/config.json" ? TarFixtureEntry(path: $0.path, kind: .file(Data("changed".utf8)), mode: $0.mode) : $0
                }
            }),
            ("mode", { fixture in
                fixture.archiveEntries = fixture.archiveEntries.map {
                    $0.path == "scripts/helper.sh" ? TarFixtureEntry(path: $0.path, kind: $0.kind, mode: 0o644) : $0
                }
            }),
            ("escape", { fixture in
                fixture.archiveEntries.append(TarFixtureEntry(path: "../escape", kind: .file(Data()), mode: 0o644))
            }),
            ("link", { fixture in
                fixture.archiveEntries = fixture.archiveEntries.map {
                    $0.path == "skills/keep/config-link" ? TarFixtureEntry(path: $0.path, kind: .symbolicLink("../../../outside"), mode: $0.mode) : $0
                }
            })
        ]

        for (name, mutate) in cases {
            var fixture = repositoryFixture()
            mutate(&fixture)
            let stagingRoot = try temporaryDirectory()
            let existing = stagingRoot.appendingPathComponent("existing/marker")
            try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: existing)
            let result = await GitHubSourceIndexer(
                apiClient: MockGitHubAPIClient(treeResult: fixture.tree, archiveData: try tarGzip(fixture.archiveEntries)),
                stager: FileSystemGitHubSourceStager(stagingRoot: stagingRoot)
            ).index(rawURL: "fixture-owner/lifecycle")

            #expect(result.issue == .contentMismatch, "case: \(name)")
            #expect(result.stagedRepository == nil, "case: \(name)")
            #expect(try Data(contentsOf: existing) == Data("keep".utf8), "case: \(name)")
        }
    }

    @Test func specialNodeNormalizationConflictAndExpandedGitlinkFail() async throws {
        let fixture = repositoryFixture()
        let cases: [(GitHubTreeSnapshot, [TarFixtureEntry])] = [
            (fixture.tree, fixture.archiveEntries + [TarFixtureEntry(path: "device", kind: .special, mode: 0o644)]),
            (fixture.tree, fixture.archiveEntries + [TarFixtureEntry(path: "SHARED/config.json", kind: .file(Data()), mode: 0o644)]),
            (GitHubTreeSnapshot(entries: [
                GitHubTreeEntry(path: "alias", kind: .blob, mode: "120000", objectID: gitBlobID(Data("shared".utf8))),
                blobEntry("alias/file", Data("write-through".utf8))
            ], isTruncated: false), [
                TarFixtureEntry(path: "alias", kind: .symbolicLink("shared"), mode: 0o777),
                TarFixtureEntry(path: "alias/file", kind: .file(Data("write-through".utf8)), mode: 0o644)
            ]),
            (GitHubTreeSnapshot(entries: fixture.tree.entries + [
                GitHubTreeEntry(path: "vendor/tool", kind: .gitlink, mode: "160000", objectID: commitB)
            ], isTruncated: false), fixture.archiveEntries + [
                TarFixtureEntry(path: "vendor/tool/file", kind: .file(Data("expanded".utf8)), mode: 0o644)
            ])
        ]

        for (tree, archiveEntries) in cases {
            let result = await GitHubSourceIndexer(
                apiClient: MockGitHubAPIClient(treeResult: tree, archiveData: try tarGzip(archiveEntries)),
                stager: FileSystemGitHubSourceStager(stagingRoot: try temporaryDirectory())
            ).index(rawURL: "fixture-owner/lifecycle")
            #expect(result.issue == .contentMismatch || result.issue == .archiveInvalid)
            #expect(result.stagedRepository == nil)
        }
    }

    @Test func gitlinkAndLFSPointerRemainExplicitRisks() async throws {
        let skill = Data(skillText(name: "Root", description: "Root skill.").utf8)
        let lfs = Data("version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 123\n".utf8)
        let tree = GitHubTreeSnapshot(entries: [
            blobEntry("SKILL.md", skill),
            blobEntry("asset.bin", lfs),
            GitHubTreeEntry(path: "vendor/tool", kind: .gitlink, mode: "160000", objectID: commitB)
        ], isTruncated: false)
        let archive = try tarGzip([
            TarFixtureEntry(path: "SKILL.md", kind: .file(skill), mode: 0o644),
            TarFixtureEntry(path: "asset.bin", kind: .file(lfs), mode: 0o644)
        ])
        let result = await GitHubSourceIndexer(
            apiClient: MockGitHubAPIClient(treeResult: tree, archiveData: archive),
            stager: FileSystemGitHubSourceStager(stagingRoot: try temporaryDirectory())
        ).index(rawURL: "fixture-owner/lifecycle")

        let staged = try #require(result.stagedRepository)
        #expect(staged.risks == [.gitlink, .lfsPointer])
        #expect(staged.externalDependencies == [
            GitHubExternalDependency(path: "asset.bin", kind: .lfsPointer, objectID: gitBlobID(lfs)),
            GitHubExternalDependency(path: "vendor/tool", kind: .gitlink, objectID: commitB)
        ])
        #expect(FileManager.default.fileExists(atPath: staged.directory.appendingPathComponent("vendor/tool").path))
    }

    @Test func zeroCandidatesInvalidCandidatesTruncationAndBudgetAreDistinct() async throws {
        let emptyData = Data("readme".utf8)
        let emptyTree = GitHubTreeSnapshot(entries: [blobEntry("README.md", emptyData)], isTruncated: false)
        let emptyStagingRoot = try temporaryDirectory()
        let emptyResult = await GitHubSourceIndexer(
            apiClient: MockGitHubAPIClient(
                treeResult: emptyTree,
                archiveData: try tarGzip([TarFixtureEntry(path: "README.md", kind: .file(emptyData), mode: 0o644)])
            ),
            stager: FileSystemGitHubSourceStager(stagingRoot: emptyStagingRoot)
        ).index(rawURL: "fixture-owner/lifecycle")
        #expect(emptyResult.issue == .noSkills)
        #expect(try FileManager.default.contentsOfDirectory(atPath: emptyStagingRoot.path).isEmpty)

        let invalid = Data("---\nname: [broken\ndescription: Text\n---".utf8)
        let invalidResult = await GitHubSourceIndexer(
            apiClient: MockGitHubAPIClient(
                treeResult: GitHubTreeSnapshot(entries: [blobEntry("SKILL.md", invalid)], isTruncated: false),
                archiveData: try tarGzip([TarFixtureEntry(path: "SKILL.md", kind: .file(invalid), mode: 0o644)])
            ),
            stager: FileSystemGitHubSourceStager(stagingRoot: try temporaryDirectory())
        ).index(rawURL: "fixture-owner/lifecycle")
        #expect(invalidResult.issue == nil)
        #expect(invalidResult.availableSkills.first?.checkStatus == .blocked)

        let truncatedResult = await GitHubSourceIndexer(
            apiClient: MockGitHubAPIClient(treeResult: GitHubTreeSnapshot(entries: [], isTruncated: true), archiveData: Data()),
            stager: MockGitHubSourceStager()
        ).index(rawURL: "fixture-owner/lifecycle")
        #expect(truncatedResult.issue == .treeTruncated)

        let fixture = repositoryFixture()
        let budgetResult = await GitHubSourceIndexer(
            apiClient: MockGitHubAPIClient(treeResult: fixture.tree, archiveData: try tarGzip(fixture.archiveEntries)),
            stager: FileSystemGitHubSourceStager(stagingRoot: try temporaryDirectory(), maximumExpandedByteCount: 10)
        ).index(rawURL: "fixture-owner/lifecycle")
        #expect(budgetResult.issue == .repositoryTooLarge)

        let diskResult = await GitHubSourceIndexer(
            apiClient: MockGitHubAPIClient(treeResult: fixture.tree, archiveData: try tarGzip(fixture.archiveEntries)),
            stager: FileSystemGitHubSourceStager(stagingRoot: try temporaryDirectory(), availableCapacity: { _ in 0 })
        ).index(rawURL: "fixture-owner/lifecycle")
        #expect(diskResult.issue == .repositoryTooLarge)

        let timeoutResult = await GitHubSourceIndexer(
            apiClient: MockGitHubAPIClient(treeResult: fixture.tree, archiveData: try tarGzip(fixture.archiveEntries)),
            stager: FileSystemGitHubSourceStager(stagingRoot: try temporaryDirectory(), maximumElapsed: -1)
        ).index(rawURL: "fixture-owner/lifecycle")
        #expect(timeoutResult.issue == .timedOut)

        let unterminatedResult = await GitHubSourceIndexer(
            apiClient: MockGitHubAPIClient(
                treeResult: fixture.tree,
                archiveData: try tarGzip(fixture.archiveEntries, includeTerminator: false)
            ),
            stager: FileSystemGitHubSourceStager(stagingRoot: try temporaryDirectory())
        ).index(rawURL: "fixture-owner/lifecycle")
        #expect(unterminatedResult.issue == .archiveInvalid)

        let cancelledTask = Task {
            await Task.yield()
            return await GitHubSourceIndexer(
                apiClient: MockGitHubAPIClient(treeResult: fixture.tree, archiveData: try tarGzip(fixture.archiveEntries)),
                stager: FileSystemGitHubSourceStager(stagingRoot: try temporaryDirectory())
            ).index(rawURL: "fixture-owner/lifecycle")
        }
        cancelledTask.cancel()
        let cancelledResult = try await cancelledTask.value
        #expect(cancelledResult.issue == .cancelled)
    }

    @Test func parserAcceptsOnlyUnversionedGitHubRepositoryRoots() throws {
        let parser = GitHubRepositoryParser()
        let reference = try parser.parse("https://github.com/acme/skills.git")
        #expect(reference.owner == "acme")
        #expect(reference.repo == "skills")
        #expect(throws: GitHubSourceIssue.unsupportedProvider) { _ = try parser.parse("https://gitlab.com/acme/skills") }
        #expect(throws: GitHubSourceIssue.unsupportedVersion) { _ = try parser.parse("https://github.com/acme/skills/tree/main") }
        #expect(throws: GitHubSourceIssue.unsupportedVersion) { _ = try parser.parse("https://github.com/acme/skills/commit/\(commitA)") }
    }

    @Test func sourceNameDisplayStillUsesRepositoryIdentity() {
        let source = SkillSource(kind: .githubRepository, name: "", urlString: "https://github.com/acme/skills")
        #expect(SkillCatalogPresentationService().sourceName(for: source) == "acme/skills")
    }

    @Test func restClientPinsTreeArchiveAndBlobToResolvedCommit() async throws {
        let file = Data("payload".utf8)
        let objectID = gitBlobID(file)
        let http = MockHTTPDataClient()
        http.enqueue(data: #"{"id":42,"name":"lifecycle","owner":{"login":"fixture-owner"},"default_branch":"main"}"#.data(using: .utf8)!, statusCode: 200)
        http.enqueue(data: #"{"ref":"refs/heads/main","object":{"type":"commit","sha":"1111111111111111111111111111111111111111"}}"#.data(using: .utf8)!, statusCode: 200)
        http.enqueue(data: """
        {"tree":[{"path":"payload","mode":"100644","type":"blob","sha":"\(objectID)","size":7}],"truncated":false}
        """.data(using: .utf8)!, statusCode: 200)
        http.enqueue(data: Data([1, 2, 3]), statusCode: 200)
        http.enqueue(data: """
        {"sha":"\(objectID)","encoding":"base64","content":"\(file.base64EncodedString())"}
        """.data(using: .utf8)!, statusCode: 200)
        let client = GitHubRESTAPIClient(httpClient: http, apiBaseURL: URL(string: "https://api.test")!)
        let repository = try await client.resolve(GitHubRepositoryIdentity(owner: "fixture-owner", repo: "lifecycle"), trackedBranch: nil)
        let tree = try await client.tree(for: repository)
        _ = try await client.archive(for: repository)
        #expect(try await client.blob(objectID: objectID, repository: repository) == file)

        #expect(tree.entries == [GitHubTreeEntry(path: "payload", kind: .blob, mode: "100644", objectID: objectID, byteCount: 7)])
        #expect(http.requests.map { $0.url?.absoluteString } == [
            "https://api.test/repos/fixture-owner/lifecycle",
            "https://api.test/repos/fixture-owner/lifecycle/git/ref/heads/main",
            "https://api.test/repos/fixture-owner/lifecycle/git/trees/\(commitA)?recursive=1",
            "https://api.test/repos/fixture-owner/lifecycle/tarball/\(commitA)",
            "https://api.test/repos/fixture-owner/lifecycle/git/blobs/\(objectID)"
        ])
        #expect(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func updateKeepsRecordedBranchAndErrorKinds() async throws {
        let http = MockHTTPDataClient()
        http.enqueue(data: #"{"id":42,"name":"lifecycle","owner":{"login":"fixture-owner"},"default_branch":"release"}"#.data(using: .utf8)!, statusCode: 200)
        http.enqueue(data: #"{"ref":"refs/heads/main","object":{"type":"commit","sha":"2222222222222222222222222222222222222222"}}"#.data(using: .utf8)!, statusCode: 200)
        let client = GitHubRESTAPIClient(httpClient: http, apiBaseURL: URL(string: "https://api.test")!)
        let repository = try await client.resolve(
            GitHubRepositoryIdentity(repositoryID: 42, owner: "fixture-owner", repo: "lifecycle"),
            trackedBranch: "main"
        )
        #expect(repository.branch == "main")
        #expect(repository.commitSHA == commitB)

        let failures: [(GitHubAPIClientFailure, GitHubSourceIssue)] = [
            (.networkFailure, .networkFailure), (.rateLimited(retryAfter: 60), .rateLimited),
            (.repositoryTooLarge, .repositoryTooLarge), (.pathRestricted, .pathRestricted),
            (.repositoryChanged, .repositoryChanged), (.branchUnavailable, .branchUnavailable),
            (.timedOut, .timedOut), (.cancelled, .cancelled),
            (.invalidArchive, .archiveInvalid), (.contentMismatch, .contentMismatch)
        ]
        for (failure, issue) in failures {
            let result = await GitHubSourceIndexer(apiClient: MockGitHubAPIClient(failure: failure), stager: MockGitHubSourceStager())
                .index(rawURL: "fixture-owner/lifecycle")
            #expect(result.issue == issue)
            #expect(result.stagedRepository == nil)
        }
    }
}

nonisolated private final class MockGitHubAPIClient: GitHubAPIClient {
    var treeResult: GitHubTreeSnapshot
    var archiveData: Data
    var blobs: [String: Data]
    var failure: GitHubAPIClientFailure?
    var commitSHA: String
    var requestedReferences: [GitHubRepositoryReference] = []
    var requestedBlobIDs: [String] = []

    init(treeResult: GitHubTreeSnapshot = GitHubTreeSnapshot(entries: [], isTruncated: false), archiveData: Data = Data(), blobs: [String: Data] = [:], failure: GitHubAPIClientFailure? = nil, commitSHA: String = commitA) {
        self.treeResult = treeResult
        self.archiveData = archiveData
        self.blobs = blobs
        self.failure = failure
        self.commitSHA = commitSHA
    }

    func resolve(_ identity: GitHubRepositoryIdentity, trackedBranch: String?) async throws -> GitHubRepositoryReference {
        if let failure { throw failure }
        return GitHubRepositoryReference(repositoryID: identity.repositoryID ?? 42, owner: identity.owner, repo: identity.repo, branch: trackedBranch ?? "main", commitSHA: commitSHA)
    }

    func tree(for repository: GitHubRepositoryReference) async throws -> GitHubTreeSnapshot {
        requestedReferences.append(repository)
        if let failure { throw failure }
        return treeResult
    }

    func archive(for repository: GitHubRepositoryReference) async throws -> Data {
        requestedReferences.append(repository)
        if let failure { throw failure }
        return archiveData
    }

    func blob(objectID: String, repository: GitHubRepositoryReference) async throws -> Data {
        requestedReferences.append(repository)
        requestedBlobIDs.append(objectID)
        if let failure { throw failure }
        guard let data = blobs[objectID] else { throw GitHubAPIClientFailure.networkFailure }
        return data
    }
}

nonisolated private final class MockGitHubSourceStager: GitHubSourceStaging {
    func stage(archive: Data, tree: GitHubTreeSnapshot, repository: GitHubRepositoryReference, blobLoader: (String) async throws -> Data) async throws -> GitHubStagedRepository {
        throw GitHubAPIClientFailure.networkFailure
    }

    func discard(_ stagedRepository: GitHubStagedRepository) throws {}
}

nonisolated private final class MockHTTPDataClient: HTTPDataClient {
    struct Response { var result: Result<(Data, Int, [String: String]), Error> }
    var requests: [URLRequest] = []
    private var responses: [Response] = []
    func enqueue(data: Data, statusCode: Int, headers: [String: String] = [:]) { responses.append(Response(result: .success((data, statusCode, headers)))) }
    func enqueue(error: Error) { responses.append(Response(result: .failure(error))) }
    func data(for request: URLRequest, maximumByteCount: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (data, statusCode, headers) = try responses.removeFirst().result.get()
        guard data.count <= maximumByteCount else { throw GitHubAPIClientFailure.repositoryTooLarge }
        return (data, HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: headers)!)
    }
}

private struct RepositoryFixture {
    var archiveEntries: [TarFixtureEntry]
    var tree: GitHubTreeSnapshot
    var expandedByteCount: Int64
}

private struct TarFixtureEntry {
    enum Kind { case file(Data), symbolicLink(String), directory, special }
    var path: String
    var kind: Kind
    var mode: UInt64
}

private func repositoryFixture() -> RepositoryFixture {
    let entries = [
        TarFixtureEntry(path: "SKILL.md", kind: .file(Data(skillText(name: "Root", description: "Root repository skill.").utf8)), mode: 0o644),
        TarFixtureEntry(path: ".hidden/deep/SKILL.md", kind: .file(Data(skillText(name: "Hidden", description: "Hidden skill.").utf8)), mode: 0o644),
        TarFixtureEntry(path: "skills/keep/SKILL.md", kind: .file(Data(skillText(name: "Keep", description: "Kept skill.").utf8)), mode: 0o644),
        TarFixtureEntry(path: "skills/remove/SKILL.md", kind: .file(Data(skillText(name: "Remove", description: "Removed in B.").utf8)), mode: 0o644),
        TarFixtureEntry(path: "skills/move/SKILL.md", kind: .file(Data(skillText(name: "Move", description: "Moved in B.").utf8)), mode: 0o644),
        TarFixtureEntry(path: "shared/config.json", kind: .file(Data("{\"enabled\":true}".utf8)), mode: 0o644),
        TarFixtureEntry(path: "scripts/helper.sh", kind: .file(Data("#!/bin/sh\nexit 0\n".utf8)), mode: 0o755),
        TarFixtureEntry(path: "assets/icon.bin", kind: .file(Data([0, 255, 1, 2])), mode: 0o644),
        TarFixtureEntry(path: "skills/keep/config-link", kind: .symbolicLink("../../shared/config.json"), mode: 0o777)
    ]
    return makeRepositoryFixture(entries)
}

private func repositoryFixtureB() -> RepositoryFixture {
    var entries = repositoryFixture().archiveEntries.filter {
        $0.path != "skills/remove/SKILL.md" && $0.path != "skills/move/SKILL.md"
    }
    entries = entries.map { entry in
        switch entry.path {
        case "skills/keep/SKILL.md":
            TarFixtureEntry(path: entry.path, kind: .file(Data(skillText(name: "Keep Updated", description: "Updated skill.").utf8)), mode: entry.mode)
        case "shared/config.json":
            TarFixtureEntry(path: entry.path, kind: .file(Data("{\"enabled\":false}".utf8)), mode: entry.mode)
        default: entry
        }
    }
    entries.append(TarFixtureEntry(path: "skills/moved/SKILL.md", kind: .file(Data(skillText(name: "Move", description: "Moved in B.").utf8)), mode: 0o644))
    entries.append(TarFixtureEntry(path: "skills/new/SKILL.md", kind: .file(Data(skillText(name: "New", description: "New in B.").utf8)), mode: 0o644))
    return makeRepositoryFixture(entries)
}

private func makeRepositoryFixture(_ entries: [TarFixtureEntry]) -> RepositoryFixture {
    let treeEntries = entries.compactMap { entry -> GitHubTreeEntry? in
        switch entry.kind {
        case .file(let data): return blobEntry(entry.path, data, executable: entry.mode & 0o111 != 0)
        case .symbolicLink(let target): return GitHubTreeEntry(path: entry.path, kind: .blob, mode: "120000", objectID: gitBlobID(Data(target.utf8)), byteCount: Int64(target.utf8.count))
        case .directory, .special: return nil
        }
    }
    let bytes = entries.reduce(Int64(0)) { total, entry in
        switch entry.kind {
        case .file(let data): total + Int64(data.count)
        case .symbolicLink(let target): total + Int64(target.utf8.count)
        case .directory, .special: total
        }
    }
    return RepositoryFixture(archiveEntries: entries, tree: GitHubTreeSnapshot(entries: treeEntries, isTruncated: false), expandedByteCount: bytes)
}

private func blobEntry(_ path: String, _ data: Data, executable: Bool = false) -> GitHubTreeEntry {
    GitHubTreeEntry(path: path, kind: .blob, mode: executable ? "100755" : "100644", objectID: gitBlobID(data), byteCount: Int64(data.count))
}

private func gitBlobID(_ data: Data, sha256: Bool = false) -> String {
    var object = Data("blob \(data.count)\0".utf8)
    object.append(data)
    if sha256 { return SHA256.hash(data: object).map { String(format: "%02x", $0) }.joined() }
    return Insecure.SHA1.hash(data: object).map { String(format: "%02x", $0) }.joined()
}

private func tarGzip(_ entries: [TarFixtureEntry], commitSHA: String = commitA, includeTerminator: Bool = true, globalPAX: Data? = nil) throws -> Data {
    var tar = Data()
    let metadata = globalPAX ?? Data("52 comment=\(commitSHA)\n".utf8)
    tar.append(tarHeader(path: "pax_global_header", kind: .file(metadata), mode: 0o644, size: metadata.count, typeFlag: 103))
    tar.append(metadata)
    tar.append(Data(repeating: 0, count: (512 - metadata.count % 512) % 512))
    let root = "fixture-owner-lifecycle-\(commitSHA)/"
    tar.append(tarHeader(path: root, kind: .directory, mode: 0o755, size: 0))
    for entry in entries {
        let path = root + entry.path
        switch entry.kind {
        case .file(let data):
            tar.append(tarHeader(path: path, kind: entry.kind, mode: entry.mode, size: data.count))
            tar.append(data)
            tar.append(Data(repeating: 0, count: (512 - data.count % 512) % 512))
        case .symbolicLink, .directory, .special:
            tar.append(tarHeader(path: path, kind: entry.kind, mode: entry.mode, size: 0))
        }
    }
    if includeTerminator { tar.append(Data(repeating: 0, count: 1_024)) }
    return try gzip(tar)
}

private func tarHeader(path: String, kind: TarFixtureEntry.Kind, mode: UInt64, size: Int, typeFlag: UInt8? = nil) -> Data {
    var header = Data(repeating: 0, count: 512)
    writeTarString(path, to: &header, range: 0..<100)
    writeTarOctal(mode, to: &header, range: 100..<108)
    writeTarOctal(0, to: &header, range: 108..<116)
    writeTarOctal(0, to: &header, range: 116..<124)
    writeTarOctal(UInt64(size), to: &header, range: 124..<136)
    writeTarOctal(0, to: &header, range: 136..<148)
    for index in 148..<156 { header[index] = 32 }
    switch kind {
    case .file: header[156] = 48
    case .symbolicLink(let target): header[156] = 50; writeTarString(target, to: &header, range: 157..<257)
    case .directory: header[156] = 53
    case .special: header[156] = 51
    }
    if let typeFlag { header[156] = typeFlag }
    writeTarString("ustar", to: &header, range: 257..<263)
    writeTarString("00", to: &header, range: 263..<265)
    writeTarOctal(header.reduce(UInt64(0)) { $0 + UInt64($1) }, to: &header, range: 148..<156)
    return header
}

private func writeTarString(_ value: String, to data: inout Data, range: Range<Int>) {
    for (offset, byte) in value.utf8.prefix(range.count).enumerated() { data[range.lowerBound + offset] = byte }
}

private func writeTarOctal(_ value: UInt64, to data: inout Data, range: Range<Int>) {
    writeTarString(String(value, radix: 8).leftPadded(to: range.count - 1) + "\0", to: &data, range: range)
}

private func gzip(_ data: Data) throws -> Data {
    var stream = z_stream()
    guard deflateInit2_(&stream, Z_BEST_SPEED, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        throw GitHubAPIClientFailure.invalidArchive
    }
    defer { deflateEnd(&stream) }
    var output = Data()
    let status = data.withUnsafeBytes { source -> Int32 in
        stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(source.count)
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        var result = Int32(Z_OK)
        repeat {
            result = buffer.withUnsafeMutableBytes { destination in
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(destination.count)
                return deflate(&stream, Z_FINISH)
            }
            output.append(contentsOf: buffer.prefix(buffer.count - Int(stream.avail_out)))
        } while result == Z_OK
        return result
    }
    guard status == Z_STREAM_END else { throw GitHubAPIClientFailure.invalidArchive }
    return output
}

private func skillText(name: String, description: String) -> String {
    """
    ---
    name: \(name)
    description: \(description)
    ---
    Body.
    """
}

private extension String {
    func leftPadded(to length: Int) -> String { String(repeating: "0", count: max(0, length - count)) + self }
}

private let commitA = "1111111111111111111111111111111111111111"
private let commitB = "2222222222222222222222222222222222222222"
