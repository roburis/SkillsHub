import Darwin
import Foundation

nonisolated enum RelationLinkPrimitiveHookPoint: Equatable, Sendable {
    case beforeCreate
    case afterCreate
    case beforePublish
    case afterPublish
    case beforeRemovalPreflight
    case beforeRemovalPin
    case beforeIsolation
    case afterIsolation
    case beforeUnlink
    case afterUnlink
    case beforeRestore
    case afterRestore
}

nonisolated enum RelationLinkPrimitiveError: Error, Equatable, Sendable {
    case invalidLinkPath
    case parentUnavailable(Int32)
    case occupied
    case createFailed(Int32)
    case createdNodeChanged
    case identityChanged
    case publicationFailed(Int32)
    case synchronizationFailed(Int32)
    case isolationFailed(Int32)
    case removalFailed(Int32)
    case replacementRestored
    case replacementRetained
    case isolationChanged
}

nonisolated struct LinkNodeIdentity: Codable, Hashable, Sendable {
    let file: TargetFileIdentity
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let generation: UInt32
    let kind: UInt16

    init(_ status: stat) {
        file = TargetFileIdentity(volumeNumber: UInt64(status.st_dev), fileNumber: UInt64(status.st_ino))
        birthSeconds = Int64(status.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
        generation = status.st_gen
        kind = status.st_mode & mode_t(S_IFMT)
    }

    static func read(at url: URL) throws -> Self {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw RelationLinkPrimitiveError.identityChanged
        }
        return Self(status)
    }
}

nonisolated struct LinkCreationEvidence: Codable, Hashable, Sendable {
    let operationID: UUID
    let stagingPath: String
    let parentIdentity: LinkNodeIdentity
    let stagingDirectoryIdentity: LinkNodeIdentity
    let nodeIdentity: LinkNodeIdentity
    let linkText: String
}

nonisolated struct ManagedLinkNode: Equatable, Sendable {
    let linkURL: URL
    let linkText: String
    let fileIdentity: TargetFileIdentity
    let creation: LinkCreationEvidence
}

nonisolated struct LinkRemovalEvidence: Codable, Equatable, Sendable {
    let creation: LinkCreationEvidence
    let isolationPath: String
    let operationDirectoryIdentity: LinkNodeIdentity
    let isolationDirectoryIdentity: LinkNodeIdentity
}

nonisolated final class AgentLinkService {
    private let relationPrimitiveHook: (@Sendable (RelationLinkPrimitiveHookPoint, URL) throws -> Void)?

    init(
        relationPrimitiveHook: (@Sendable (RelationLinkPrimitiveHookPoint, URL) throws -> Void)? = nil
    ) {
        self.relationPrimitiveHook = relationPrimitiveHook
    }

    func createManagedLink(
        at linkURL: URL,
        linkText: String,
        operationID: UUID,
        expectedParentIdentity: LinkNodeIdentity,
        recordPreparation: (URL) throws -> Void,
        recordCreation: (LinkCreationEvidence) throws -> Void,
        onCreated: (URL) -> Void
    ) throws -> ManagedLinkNode {
        let location = try relationLocation(for: linkURL)
        guard !linkText.isEmpty, !linkText.utf8.contains(0) else {
            throw RelationLinkPrimitiveError.invalidLinkPath
        }
        return try withDirectoryDescriptor(for: location.parentURL) { descriptor in
            let parentIdentity = try descriptorIdentity(descriptor)
            guard parentIdentity == expectedParentIdentity else {
                throw RelationLinkPrimitiveError.identityChanged
            }
            let stagingName = ".skillshub-create-\(operationID.uuidString)"
            let stagingDirectory = location.parentURL.appendingPathComponent(stagingName, isDirectory: true)
            let stagingURL = stagingDirectory.appendingPathComponent("link")
            try recordPreparation(stagingURL)
            try relationPrimitiveHook?(.beforeCreate, location.linkURL)
            try verifyParent(location.parentURL, identity: parentIdentity)
            guard Darwin.mkdirat(descriptor, stagingName, 0o700) == 0 else {
                throw RelationLinkPrimitiveError.createFailed(errno)
            }
            // Retain the private directory on every outcome; recovery owns its disposition.
            let stagingDescriptor = Darwin.openat(descriptor, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard stagingDescriptor >= 0 else {
                throw RelationLinkPrimitiveError.parentUnavailable(errno)
            }
            defer { Darwin.close(stagingDescriptor) }
            let stagingIdentity = try descriptorIdentity(stagingDescriptor)
            try verifyParent(stagingDirectory, identity: stagingIdentity)
            guard Darwin.symlinkat(linkText, stagingDescriptor, "link") == 0 else {
                throw RelationLinkPrimitiveError.createFailed(errno)
            }
            onCreated(stagingURL)
            // Pin the actual symlink until publication/readback has finished, preventing inode reuse.
            let nodeDescriptor = Darwin.openat(stagingDescriptor, "link", O_RDONLY | O_SYMLINK | O_CLOEXEC)
            guard nodeDescriptor >= 0 else {
                throw RelationLinkPrimitiveError.createdNodeChanged
            }
            defer { Darwin.close(nodeDescriptor) }
            let nodeIdentity = try descriptorIdentity(nodeDescriptor)
            guard nodeIdentity.kind == S_IFLNK, nodeIdentity.birthSeconds > 0 else {
                throw RelationLinkPrimitiveError.createdNodeChanged
            }
            let creation = LinkCreationEvidence(
                operationID: operationID, stagingPath: stagingURL.path,
                parentIdentity: parentIdentity, stagingDirectoryIdentity: stagingIdentity,
                nodeIdentity: nodeIdentity, linkText: linkText
            )
            try verifyNode(descriptor: stagingDescriptor, name: "link", creation: creation)
            try synchronize(stagingDescriptor)
            try synchronize(descriptor)
            try recordCreation(creation)
            try relationPrimitiveHook?(.afterCreate, stagingURL)
            try relationPrimitiveHook?(.beforePublish, stagingURL)
            try verifyParent(location.parentURL, identity: parentIdentity)
            try verifyParent(stagingDirectory, identity: stagingIdentity)
            try verifyNode(descriptor: stagingDescriptor, name: "link", creation: creation)
            // Re-read durable evidence at the publication boundary as well as after creation.
            try recordCreation(creation)
            try verifyParent(location.parentURL, identity: parentIdentity)
            try verifyParent(stagingDirectory, identity: stagingIdentity)
            try verifyNode(descriptor: stagingDescriptor, name: "link", creation: creation)
            let result = Darwin.renameatx_np(stagingDescriptor, "link", descriptor, location.name, UInt32(RENAME_EXCL))
            guard result == 0 else {
                if errno == EEXIST { throw RelationLinkPrimitiveError.occupied }
                throw RelationLinkPrimitiveError.publicationFailed(errno)
            }
            onCreated(location.linkURL)
            try relationPrimitiveHook?(.afterPublish, location.linkURL)
            try synchronize(stagingDescriptor)
            try synchronize(descriptor)
            try verifyParent(location.parentURL, identity: parentIdentity)
            try verifyParent(stagingDirectory, identity: stagingIdentity)
            try verifyNode(descriptor: descriptor, name: location.name, creation: creation)
            return ManagedLinkNode(linkURL: location.linkURL, linkText: linkText,
                                   fileIdentity: nodeIdentity.file, creation: creation)
        }
    }

    // V-001 qualified on macOS/APFS; every call still verifies identity and filesystem support.
    func removeManagedLink(
        at linkURL: URL,
        creation: LinkCreationEvidence,
        operationDirectory: URL,
        expectedOperationIdentity: TargetFileIdentity,
        recordIsolation: (LinkRemovalEvidence) throws -> Void,
        verifyRecord: () throws -> Void,
        onEvent: (RelationActionFileEvent) -> Void
    ) throws {
        let location = try relationLocation(for: linkURL)
        guard creation.nodeIdentity.kind == S_IFLNK, creation.nodeIdentity.birthSeconds > 0,
              creation.parentIdentity.kind == S_IFDIR else {
            throw RelationLinkPrimitiveError.identityChanged
        }
        try relationPrimitiveHook?(.beforeRemovalPreflight, linkURL)
        try withDirectoryDescriptor(for: location.parentURL) { parent in
            try verifyParent(location.parentURL, identity: creation.parentIdentity)
            guard try descriptorIdentity(parent) == creation.parentIdentity else {
                throw RelationLinkPrimitiveError.identityChanged
            }
            try verifyNode(descriptor: parent, name: location.name, creation: creation)
            // Keep the authorized inode alive throughout the move, including replacement races.
            try relationPrimitiveHook?(.beforeRemovalPin, linkURL)
            let node = Darwin.openat(parent, location.name, O_RDONLY | O_SYMLINK | O_NONBLOCK | O_CLOEXEC)
            guard node >= 0 else { throw RelationLinkPrimitiveError.identityChanged }
            defer { Darwin.close(node) }
            guard try descriptorIdentity(node) == creation.nodeIdentity else {
                throw RelationLinkPrimitiveError.identityChanged
            }
            try withDirectoryDescriptor(for: operationDirectory) { operation in
                let operationIdentity = try descriptorIdentity(operation)
                guard operationIdentity.file == expectedOperationIdentity else {
                    throw RelationLinkPrimitiveError.identityChanged
                }
                guard operationIdentity.file.volumeNumber == creation.parentIdentity.file.volumeNumber else {
                    throw RelationLinkPrimitiveError.isolationFailed(EXDEV)
                }
                try verifyParent(operationDirectory, identity: operationIdentity)
                try verifyRecord()
                guard Darwin.mkdirat(operation, "isolation", 0o700) == 0 else {
                    throw RelationLinkPrimitiveError.isolationFailed(errno)
                }
                let directory = operationDirectory.appendingPathComponent("isolation", isDirectory: true)
                let isolated = directory.appendingPathComponent("link")
                try withDirectoryDescriptor(for: directory) { isolation in
                    let isolationIdentity = try descriptorIdentity(isolation)
                    let evidence = LinkRemovalEvidence(creation: creation, isolationPath: isolated.path,
                        operationDirectoryIdentity: operationIdentity, isolationDirectoryIdentity: isolationIdentity)
                    func verifyDirectories() throws {
                        try verifyParent(location.parentURL, identity: creation.parentIdentity)
                        try verifyParent(operationDirectory, identity: operationIdentity)
                        try verifyParent(directory, identity: isolationIdentity)
                        guard Darwin.faccessat(parent, ".", R_OK | W_OK | X_OK, 0) == 0 else {
                            throw RelationLinkPrimitiveError.isolationFailed(errno)
                        }
                        var status = stat()
                        guard Darwin.fstat(isolation, &status) == 0,
                              status.st_uid == geteuid(), status.st_mode & 0o777 == 0o700,
                              isolationIdentity.file.volumeNumber == creation.parentIdentity.file.volumeNumber else {
                            throw RelationLinkPrimitiveError.isolationChanged
                        }
                    }
                    try verifyDirectories()
                    try synchronize(isolation)
                    try synchronize(operation)
                    try recordIsolation(evidence)
                    try verifyRecord()
                    try verifyDirectories()
                    try verifyNode(descriptor: parent, name: location.name, creation: creation)
                    // This hook models the final preflight-to-rename race. Only isolation decides deletion.
                    try relationPrimitiveHook?(.beforeIsolation, linkURL)
                    try Task.checkCancellation()
                    try verifyRecord()
                    try verifyDirectories()
                    guard Darwin.renameatx_np(parent, location.name, isolation, "link", UInt32(RENAME_EXCL)) == 0 else {
                        throw RelationLinkPrimitiveError.isolationFailed(errno)
                    }
                    onEvent(.isolated(isolated.path))
                    // Do not open an unknown replacement (a FIFO/device may block or have effects).
                    let movedIdentity = try LinkNodeIdentity.read(at: isolated)
                    try relationPrimitiveHook?(.afterIsolation, isolated)
                    try synchronize(parent)
                    try synchronize(isolation)
                    try Task.checkCancellation()
                    try verifyRecord()
                    try verifyDirectories()
                    guard try LinkNodeIdentity.read(at: isolated) == movedIdentity else {
                        throw RelationLinkPrimitiveError.isolationChanged
                    }
                    if movedIdentity != creation.nodeIdentity {
                        // A replacement moved in the final race is never deleted. Restore exclusively,
                        // only on this uninterrupted call; every thrown hook/cancellation retains it.
                        try relationPrimitiveHook?(.beforeRestore, isolated)
                        try Task.checkCancellation()
                        try verifyRecord()
                        try verifyDirectories()
                        guard try LinkNodeIdentity.read(at: isolated) == movedIdentity else {
                            throw RelationLinkPrimitiveError.isolationChanged
                        }
                        var occupant = stat()
                        guard Darwin.fstatat(parent, location.name, &occupant, AT_SYMLINK_NOFOLLOW) != 0,
                              errno == ENOENT else {
                            throw RelationLinkPrimitiveError.replacementRetained
                        }
                        guard Darwin.renameatx_np(isolation, "link", parent, location.name, UInt32(RENAME_EXCL)) == 0 else {
                            throw RelationLinkPrimitiveError.isolationFailed(errno)
                        }
                        onEvent(.restored(linkURL.path))
                        try relationPrimitiveHook?(.afterRestore, linkURL)
                        try synchronize(parent)
                        try synchronize(isolation)
                        throw RelationLinkPrimitiveError.replacementRestored
                    }
                    try relationPrimitiveHook?(.beforeUnlink, isolated)
                    try Task.checkCancellation()
                    try verifyRecord()
                    try verifyDirectories()
                    try verifyNode(descriptor: isolation, name: "link", creation: creation)
                    // The private isolation boundary is required: unlinkat has no expected-inode option.
                    guard Darwin.unlinkat(isolation, "link", 0) == 0 else {
                        throw RelationLinkPrimitiveError.removalFailed(errno)
                    }
                    onEvent(.removed(isolated.path))
                    try relationPrimitiveHook?(.afterUnlink, isolated)
                    try synchronize(isolation)
                    try verifyDirectories()
                    var remaining = stat()
                    guard Darwin.fstatat(isolation, "link", &remaining, AT_SYMLINK_NOFOLLOW) != 0,
                          errno == ENOENT else {
                        throw RelationLinkPrimitiveError.isolationChanged
                    }
                }
            }
        }
    }

    private func verifyNode(
        descriptor: Int32,
        name: String,
        creation: LinkCreationEvidence
    ) throws {
        var status = stat()
        let statResult = name.withCString { pointer in
            Darwin.fstatat(descriptor, pointer, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0, LinkNodeIdentity(status) == creation.nodeIdentity else {
            throw RelationLinkPrimitiveError.createdNodeChanged
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = name.withCString { pointer in
            Darwin.readlinkat(descriptor, pointer, &buffer, buffer.count - 1)
        }
        guard count >= 0, count < buffer.count - 1 else {
            throw RelationLinkPrimitiveError.createdNodeChanged
        }
        let bytes = buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
        guard bytes.elementsEqual(creation.linkText.utf8),
              Darwin.fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
              LinkNodeIdentity(status) == creation.nodeIdentity else {
            throw RelationLinkPrimitiveError.createdNodeChanged
        }
    }

    private func descriptorIdentity(_ descriptor: Int32) throws -> LinkNodeIdentity {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw RelationLinkPrimitiveError.identityChanged
        }
        return LinkNodeIdentity(status)
    }

    private func verifyParent(_ url: URL, identity: LinkNodeIdentity) throws {
        guard identity.kind == S_IFDIR, try LinkNodeIdentity.read(at: url) == identity else {
            throw RelationLinkPrimitiveError.identityChanged
        }
    }

    private func synchronize(_ descriptor: Int32) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw RelationLinkPrimitiveError.synchronizationFailed(errno)
        }
    }

    private func withDirectoryDescriptor<Result>(
        for directoryURL: URL,
        operation: (Int32) throws -> Result
    ) throws -> Result {
        let descriptor = Darwin.open(
            directoryURL.standardizedFileURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw RelationLinkPrimitiveError.parentUnavailable(errno)
        }
        defer { Darwin.close(descriptor) }
        return try operation(descriptor)
    }

    private func relationLocation(for linkURL: URL) throws -> (
        linkURL: URL,
        parentURL: URL,
        name: String
    ) {
        let normalized = linkURL.standardizedFileURL
        let name = normalized.lastPathComponent
        guard name.isEmpty == false, name != ".", name != "..", !name.utf8.contains(0),
              linkURL.path == normalized.path else {
            throw RelationLinkPrimitiveError.invalidLinkPath
        }
        return (normalized, normalized.deletingLastPathComponent(), name)
    }
}
