import Foundation
import Testing
@testable import SkillsHub

struct FileAccessServiceTests {
    @Test func linkConflictDetectsRegularFileDirectoryWrongLinkAndBrokenLink() throws {
        let root = try temporaryDirectory()
        let expected = root.appendingPathComponent("skills/a")
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        let service = FileAccessService()

        let regularFile = root.appendingPathComponent("codex-link")
        try "content".write(to: regularFile, atomically: true, encoding: .utf8)
        #expect(service.linkConflict(at: regularFile, expectedDestination: expected)?.kind == .regularFile)

        let directory = root.appendingPathComponent("directory-link")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(service.linkConflict(at: directory, expectedDestination: expected)?.kind == .directory)

        let wrongTarget = root.appendingPathComponent("skills/b")
        try FileManager.default.createDirectory(at: wrongTarget, withIntermediateDirectories: true)
        let wrongLink = root.appendingPathComponent("wrong-link")
        try FileManager.default.createSymbolicLink(at: wrongLink, withDestinationURL: wrongTarget)
        #expect(service.linkConflict(at: wrongLink, expectedDestination: expected)?.kind == .wrongSymlink)

        let brokenLink = root.appendingPathComponent("broken-link")
        try FileManager.default.createSymbolicLink(atPath: brokenLink.path, withDestinationPath: root.appendingPathComponent("missing").path)
        #expect(service.linkConflict(at: brokenLink, expectedDestination: expected)?.kind == .brokenSymlink)
    }

    @Test func expectedExistingSymlinkIsNotAConflict() throws {
        let root = try temporaryDirectory()
        let expected = root.appendingPathComponent("skills/a")
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("codex-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: expected)

        let service = FileAccessService()
        #expect(service.linkConflict(at: link, expectedDestination: expected) == nil)
    }

    @Test func aliasConflictMatrixBlocksOccupiedPathsWithoutOverwrite() throws {
        let root = try temporaryDirectory()
        let expected = root.appendingPathComponent("local/review", isDirectory: true)
        let otherHub = root.appendingPathComponent("local/other-review", isDirectory: true)
        let external = try temporaryDirectory().appendingPathComponent("external-review", isDirectory: true)
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherHub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let service = FileAccessService()

        let ordinaryDirectory = root.appendingPathComponent("ordinary/review", isDirectory: true)
        try FileManager.default.createDirectory(at: ordinaryDirectory, withIntermediateDirectories: true)
        #expect(service.linkConflict(at: ordinaryDirectory, expectedDestination: expected)?.kind == .directory)

        let externalSymlink = root.appendingPathComponent("external/review")
        try FileManager.default.createDirectory(at: externalSymlink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: externalSymlink, withDestinationURL: external)
        let externalConflict = try #require(service.linkConflict(at: externalSymlink, expectedDestination: expected))
        #expect(externalConflict.kind == .wrongSymlink)
        #expect(externalConflict.existingTarget == external.path)

        let otherHubSymlink = root.appendingPathComponent("other-hub/review")
        try FileManager.default.createDirectory(at: otherHubSymlink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: otherHubSymlink, withDestinationURL: otherHub)
        let otherHubConflict = try #require(service.linkConflict(at: otherHubSymlink, expectedDestination: expected))
        #expect(otherHubConflict.kind == .wrongSymlink)
        #expect(otherHubConflict.existingTarget == otherHub.path)

        let brokenSymlink = root.appendingPathComponent("broken/review")
        try FileManager.default.createDirectory(at: brokenSymlink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: brokenSymlink.path,
            withDestinationPath: root.appendingPathComponent("missing-review").path
        )
        #expect(service.linkConflict(at: brokenSymlink, expectedDestination: expected)?.kind == .brokenSymlink)

        let caseDirectory = root.appendingPathComponent("case/Review", isDirectory: true)
        try FileManager.default.createDirectory(at: caseDirectory, withIntermediateDirectories: true)
        let caseConflict = try #require(service.linkConflict(
            at: root.appendingPathComponent("case/review", isDirectory: true),
            expectedDestination: expected
        ))
        #expect(caseConflict.kind == .directory)
        #expect(caseConflict.path.caseInsensitiveCompare(caseDirectory.path) == .orderedSame)
    }

    @Test func symlinkEscapeAndCycleAreExplicitFailures() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        let escapeLink = root.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: outside)
        let service = FileAccessService()

        #expect(!service.isDescendant(try service.resolvedSymlinkTarget(escapeLink), of: root))

        let first = root.appendingPathComponent("cycle-a")
        let second = root.appendingPathComponent("cycle-b")
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: second)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: first)

        #expect(throws: FileAccessFailure.symlinkCycle(path: first.path)) {
            try service.resolvedSymlinkTarget(first)
        }
        #expect(service.linkConflict(at: first, expectedDestination: outside)?.kind == .symlinkCycle)
    }
}
