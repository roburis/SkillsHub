import Foundation
import Darwin

nonisolated protocol SecurityScopedResourceAccessing: AnyObject {
    func startAccessing(_ url: URL, owner: SecurityScopedAccessOwner) -> Bool
    func stopAccessing(_ url: URL) throws
}

nonisolated final class SystemSecurityScopedResourceAccessAdapter: SecurityScopedResourceAccessing {
    func startAccessing(_ url: URL, owner: SecurityScopedAccessOwner) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) throws {
        url.stopAccessingSecurityScopedResource()
    }
}

nonisolated enum SecurityScopedAccessError: Error, Equatable {
    case startDenied(path: String, ownerIdentity: String)
}

nonisolated enum SecurityScopedAccessEndResult: Equatable, Sendable {
    case stopped
    case alreadyStopped
    case ownerMismatch(expectedOwnerIdentity: String, attemptedOwnerIdentity: String)
    case stopFailed
    case stopStatusUnknown
}

nonisolated final class SecurityScopedAccessLease {
    private enum State {
        case active
        case stopped
        case stopStatusUnknown(String)
    }

    let id: UUID
    let owner: SecurityScopedAccessOwner
    let url: URL

    private let adapter: any SecurityScopedResourceAccessing
    private let stateLock = NSLock()
    private var state: State = .active

    fileprivate init(
        id: UUID = UUID(),
        owner: SecurityScopedAccessOwner,
        url: URL,
        adapter: any SecurityScopedResourceAccessing
    ) {
        self.id = id
        self.owner = owner
        self.url = url.standardizedFileURL
        self.adapter = adapter
    }

    deinit {
        _ = end(by: owner)
    }

    var stopFailureDescription: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard case .stopStatusUnknown(let description) = state else {
            return nil
        }
        return description
    }

    func end(by requestingOwner: SecurityScopedAccessOwner) -> SecurityScopedAccessEndResult {
        guard requestingOwner == owner else {
            return .ownerMismatch(
                expectedOwnerIdentity: owner.identity,
                attemptedOwnerIdentity: requestingOwner.identity
            )
        }

        stateLock.lock()
        defer { stateLock.unlock() }
        switch state {
        case .stopped:
            return .alreadyStopped
        case .stopStatusUnknown:
            return .stopStatusUnknown
        case .active:
            do {
                try adapter.stopAccessing(url)
                state = .stopped
                return .stopped
            } catch {
                state = .stopStatusUnknown(String(describing: error))
                return .stopFailed
            }
        }
    }
}

nonisolated struct SecurityScopedAccessProvider {
    private let adapter: any SecurityScopedResourceAccessing

    init(adapter: any SecurityScopedResourceAccessing = SystemSecurityScopedResourceAccessAdapter()) {
        self.adapter = adapter
    }

    func acquire(url: URL, owner: SecurityScopedAccessOwner) throws -> SecurityScopedAccessLease {
        let normalizedURL = url.standardizedFileURL
        guard adapter.startAccessing(normalizedURL, owner: owner) else {
            throw SecurityScopedAccessError.startDenied(
                path: normalizedURL.path,
                ownerIdentity: owner.identity
            )
        }
        return SecurityScopedAccessLease(owner: owner, url: normalizedURL, adapter: adapter)
    }
}

nonisolated enum AgentTargetAccessError: Error, Equatable {
    case qualificationFailed(AgentTargetQualificationFailure)
    case leaseUnavailable
}

nonisolated final class AgentTargetAccess: @unchecked Sendable {
    let qualification: AgentTargetQualification
    let owner: SecurityScopedAccessOwner

    private let lease: SecurityScopedAccessLease

    init(
        qualification: AgentTargetQualification,
        lease: SecurityScopedAccessLease
    ) {
        self.qualification = qualification
        self.owner = lease.owner
        self.lease = lease
    }

    func revalidatedQualification() throws -> AgentTargetQualification {
        qualification
    }

    func end(by actionID: UUID) -> SecurityScopedAccessEndResult {
        let attemptedOwner = qualification.agent.map {
            SecurityScopedAccessOwner.agentTarget(actionID: actionID, agent: $0)
        } ?? .configuredAgentTarget(actionID: actionID, agentID: qualification.agentID)
        return lease.end(by: attemptedOwner)
    }

    func endByOwningAction() -> SecurityScopedAccessEndResult {
        lease.end(by: owner)
    }
}

nonisolated enum FileAccessFailure: Error, Equatable {
    case outsideAuthorizedDirectory(path: String)
    case unreadable(path: String)
    case symlinkEscapesRoot(path: String)
    case symlinkCycle(path: String)
}

nonisolated struct ManifestReadAccess {
    private let contentsHandler: (URL) throws -> [URL]
    private let resourceValuesHandler: (URL, Set<URLResourceKey>) throws -> URLResourceValues
    private let dataHandler: (URL) throws -> Data
    private let symlinkDestinationHandler: (URL) throws -> String

    init(
        fileManager: FileManager = .default,
        contentsOfDirectory: ((URL) throws -> [URL])? = nil,
        resourceValues: ((URL, Set<URLResourceKey>) throws -> URLResourceValues)? = nil,
        dataContents: ((URL) throws -> Data)? = nil,
        symlinkDestination: ((URL) throws -> String)? = nil
    ) {
        contentsHandler = contentsOfDirectory ?? { directory in
            try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .isExecutableKey,
                    .fileSizeKey
                ],
                options: []
            )
        }
        resourceValuesHandler = resourceValues ?? { url, keys in
            try url.resourceValues(forKeys: keys)
        }
        dataHandler = dataContents ?? { url in
            try Data(contentsOf: url, options: [.mappedIfSafe])
        }
        symlinkDestinationHandler = symlinkDestination ?? { url in
            try fileManager.destinationOfSymbolicLink(atPath: url.path)
        }
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try contentsHandler(url)
    }

    func resourceValues(at url: URL, forKeys keys: Set<URLResourceKey>) throws -> URLResourceValues {
        try resourceValuesHandler(url, keys)
    }

    func data(at url: URL) throws -> Data {
        try dataHandler(url)
    }

    func destinationOfSymbolicLink(at url: URL) throws -> String {
        try symlinkDestinationHandler(url)
    }
}

nonisolated enum ContentManifestReadStage: String, Equatable, Sendable {
    case enumeration
    case attributes
    case content
    case symbolicLinkTarget
}

nonisolated enum ContentManifestFailure: Error, Equatable {
    case readFailed(path: String, stage: ContentManifestReadStage)
    case unsupportedNode(path: String)
    case caseInsensitiveConflict(directoryPath: String, names: [String])
}

nonisolated enum LinkConflictKind: String, Equatable {
    case regularFile
    case directory
    case wrongSymlink
    case brokenSymlink
    case symlinkCycle
}

nonisolated struct LinkConflict: Equatable {
    var kind: LinkConflictKind
    var path: String
    var existingTarget: String?
}

nonisolated final class FileAccessService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func isDescendant(_ child: URL, of parent: URL, resolvingSymlinks: Bool = true) -> Bool {
        let childPath = normalizedPath(child, resolvingSymlinks: resolvingSymlinks)
        let parentPath = normalizedPath(parent, resolvingSymlinks: resolvingSymlinks)

        if childPath == parentPath {
            return true
        }

        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }

    // Resolve components through the caller's read boundary, including parent links.
    func resolvePath(
        _ path: String,
        relativeTo directory: URL,
        within root: URL,
        inspect: (URL, Bool) throws -> String?
    ) throws -> URL {
        let root = root.standardizedFileURL
        let directory = directory.standardizedFileURL
        guard isDescendant(directory, of: root, resolvingSymlinks: false) else {
            throw FileAccessFailure.outsideAuthorizedDirectory(path: directory.path)
        }
        let requested = directory.appendingPathComponent(path).path
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var resolved: [String] = []
        var links = 0
        func components(_ target: String) throws -> [String] {
            if target.hasPrefix("/") {
                guard target == root.path || target.hasPrefix(prefix) else {
                    throw FileAccessFailure.symlinkEscapesRoot(path: requested)
                }
                resolved = []
                return String(target.dropFirst(root.path.count)).split(separator: "/").map(String.init)
            }
            return target.split(separator: "/").map(String.init)
        }
        var remaining = String(directory.path.dropFirst(root.path.count)).split(separator: "/").map(String.init)
        remaining = path.hasPrefix("/") ? try components(path) : remaining + (try components(path))
        while !remaining.isEmpty {
            let component = remaining.removeFirst()
            if component == "." { continue }
            if component == ".." {
                guard !resolved.isEmpty else { throw FileAccessFailure.symlinkEscapesRoot(path: requested) }
                resolved.removeLast()
                continue
            }
            let url = root.appendingPathComponent((resolved + [component]).joined(separator: "/"))
            if let target = try inspect(url, !remaining.isEmpty) {
                links += 1
                guard links <= Int(MAXSYMLINKS) else { throw FileAccessFailure.symlinkCycle(path: requested) }
                remaining = try components(target) + remaining
            } else {
                resolved.append(component)
            }
        }
        return resolved.isEmpty ? root : root.appendingPathComponent(resolved.joined(separator: "/"))
    }

    func assertInsideAuthorizedDirectory(_ url: URL, authorizedDirectories: [URL]) throws {
        guard authorizedDirectories.contains(where: { isDescendant(url, of: $0) }) else {
            throw FileAccessFailure.outsideAuthorizedDirectory(path: url.path)
        }
    }

    func assertReadable(_ url: URL) throws {
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw FileAccessFailure.unreadable(path: url.path)
        }
    }

    func validateSymlinkDoesNotEscape(_ url: URL, rootURL: URL) throws {
        guard isSymlink(url) else {
            return
        }

        let target = try resolvedSymlinkTarget(url)
        guard isDescendant(target, of: rootURL) else {
            throw FileAccessFailure.symlinkEscapesRoot(path: url.path)
        }
    }

    func linkConflict(at linkURL: URL, expectedDestination: URL) -> LinkConflict? {
        if isSymlink(linkURL) {
            let symlinkDestination: URL
            do {
                symlinkDestination = try resolvedSymlinkTarget(linkURL)
            } catch FileAccessFailure.symlinkCycle {
                return LinkConflict(
                    kind: .symlinkCycle,
                    path: linkURL.path,
                    existingTarget: nil
                )
            } catch {
                return LinkConflict(
                    kind: .wrongSymlink,
                    path: linkURL.path,
                    existingTarget: nil
                )
            }
            let destinationExists = fileManager.fileExists(atPath: symlinkDestination.path)
            if normalizedPath(symlinkDestination) == normalizedPath(expectedDestination), destinationExists {
                return nil
            }
            return LinkConflict(
                kind: destinationExists ? .wrongSymlink : .brokenSymlink,
                path: linkURL.path,
                existingTarget: symlinkDestination.path
            )
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: linkURL.path, isDirectory: &isDirectory) else {
            guard let sibling = caseInsensitiveSibling(for: linkURL) else {
                return nil
            }
            return occupiedPathConflict(at: sibling)
        }

        return LinkConflict(
            kind: isDirectory.boolValue ? .directory : .regularFile,
            path: linkURL.path,
            existingTarget: nil
        )
    }

    private func caseInsensitiveSibling(for url: URL) -> URL? {
        let parent = url.deletingLastPathComponent()
        let requestedName = url.lastPathComponent
        guard let siblings = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return nil
        }
        return siblings.first { sibling in
            sibling.lastPathComponent.caseInsensitiveCompare(requestedName) == .orderedSame
                && sibling.lastPathComponent != requestedName
        }
    }

    private func occupiedPathConflict(at url: URL) -> LinkConflict {
        if isSymlink(url) {
            let destination = try? resolvedSymlinkTarget(url)
            let destinationExists = destination.map { fileManager.fileExists(atPath: $0.path) } ?? false
            return LinkConflict(
                kind: destinationExists ? .wrongSymlink : .brokenSymlink,
                path: url.path,
                existingTarget: destination?.path
            )
        }

        var isDirectory: ObjCBool = false
        _ = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return LinkConflict(
            kind: isDirectory.boolValue ? .directory : .regularFile,
            path: url.path,
            existingTarget: nil
        )
    }

    func resolvedSymlinkTarget(_ linkURL: URL) throws -> URL {
        var visited: Set<String> = []
        return try resolveSymlinkTarget(linkURL, visited: &visited)
    }

    private func normalizedPath(_ url: URL, resolvingSymlinks: Bool = true) -> String {
        let normalizedURL = resolvingSymlinks ? url.resolvingSymlinksInPath() : url
        return normalizedURL.standardizedFileURL.path
    }

    func isSymlink(_ url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return true
        }
        var statInfo = stat()
        if lstat(url.path, &statInfo) == 0, (statInfo.st_mode & S_IFMT) == S_IFLNK {
            return true
        }
        return (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func resolveSymlinkTarget(_ linkURL: URL, visited: inout Set<String>) throws -> URL {
        let standardizedLink = linkURL.standardizedFileURL
        let linkPath = standardizedLink.path
        guard !visited.contains(linkPath) else {
            throw FileAccessFailure.symlinkCycle(path: linkURL.path)
        }
        visited.insert(linkPath)

        guard isSymlink(standardizedLink) else {
            return standardizedLink
        }

        let destination = try fileManager.destinationOfSymbolicLink(atPath: linkURL.path)
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = linkURL.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return try resolveSymlinkTarget(destinationURL, visited: &visited)
    }
}
