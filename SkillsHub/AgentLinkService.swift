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
    case beforeMaterialIsolation
    case afterMaterialIsolation
    case beforeMaterialRemoval
    case afterMaterialRemoval
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

nonisolated struct CreationMaterialSettlement: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case pending, settled, retained }
    var status: Status
    var isolationPath: String? = nil
    var operationDirectoryIdentity: LinkNodeIdentity? = nil
    var isolationDirectoryIdentity: LinkNodeIdentity? = nil
    var observedIdentity: LinkNodeIdentity? = nil
    var limitation: String? = nil
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
            // Keep preparation until the caller has durably verified the published relationship.
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

    /// Uses the existing durable operation directory as the private isolation owner. A different
    /// volume retains preparation; it never prevents link publication or falls back to path rmdir.
    func settleCreationDirectory(
        creation: LinkCreationEvidence,
        operationDirectory: URL,
        expectedOperationIdentity: TargetFileIdentity,
        previous: CreationMaterialSettlement?,
        recordSettlement: (CreationMaterialSettlement) throws -> Void,
        verifyRecord: () throws -> Void
    ) throws {
        let staging = URL(fileURLWithPath: creation.stagingPath).deletingLastPathComponent()
        let location = try relationLocation(for: staging)
        try withDirectoryDescriptor(for: location.parentURL) { parent in
            guard try descriptorIdentity(parent) == creation.parentIdentity else {
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
                let directory = operationDirectory.appendingPathComponent("creation-settlement", isDirectory: true)
                let isolated = directory.appendingPathComponent("directory", isDirectory: true)
                if previous?.isolationPath == nil {
                    try verifyRecord()
                    try verifyParent(operationDirectory, identity: operationIdentity)
                    guard Darwin.mkdirat(operation, "creation-settlement", 0o700) == 0 else {
                        throw RelationLinkPrimitiveError.isolationFailed(errno)
                    }
                }
                try withDirectoryDescriptor(for: directory) { isolation in
                    let isolationIdentity = try descriptorIdentity(isolation)
                    if let previous, previous.isolationPath != nil {
                        guard previous.isolationPath == isolated.path,
                              previous.operationDirectoryIdentity == operationIdentity,
                              previous.isolationDirectoryIdentity == isolationIdentity else {
                            throw RelationLinkPrimitiveError.isolationChanged
                        }
                    }
                    var settlement = CreationMaterialSettlement(status: .pending,
                        isolationPath: isolated.path, operationDirectoryIdentity: operationIdentity,
                        isolationDirectoryIdentity: isolationIdentity)
                    func verifyDirectories() throws {
                        try verifyParent(location.parentURL, identity: creation.parentIdentity)
                        try verifyParent(operationDirectory, identity: operationIdentity)
                        try verifyParent(directory, identity: isolationIdentity)
                        var status = stat()
                        guard Darwin.fstat(isolation, &status) == 0,
                              status.st_uid == geteuid(), status.st_mode & 0o777 == 0o700 else {
                            throw RelationLinkPrimitiveError.isolationChanged
                        }
                    }
                    try verifyDirectories()
                    try synchronize(isolation)
                    try synchronize(operation)
                    // Persist both possible locations before the first irreversible filesystem action.
                    try recordSettlement(settlement)
                    let sourceIdentity = try nodeIdentity(descriptor: parent, name: location.name)
                    let isolatedIdentity = try nodeIdentity(descriptor: isolation, name: "directory")
                    let nodeParent: Int32
                    let nodeName: String
                    if isolatedIdentity != nil {
                        guard sourceIdentity == nil, isolatedIdentity == creation.stagingDirectoryIdentity,
                              previous?.isolationPath == isolated.path else {
                            throw RelationLinkPrimitiveError.replacementRetained
                        }
                        nodeParent = isolation
                        nodeName = "directory"
                    } else {
                        guard sourceIdentity == creation.stagingDirectoryIdentity else {
                            throw RelationLinkPrimitiveError.identityChanged
                        }
                        nodeParent = parent
                        nodeName = location.name
                    }
                    let node = Darwin.openat(nodeParent, nodeName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard node >= 0 else { throw RelationLinkPrimitiveError.identityChanged }
                    defer { Darwin.close(node) }
                    guard try descriptorIdentity(node) == creation.stagingDirectoryIdentity,
                          try directoryIsEmpty(node) else {
                        throw RelationLinkPrimitiveError.identityChanged
                    }
                    if nodeParent == parent {
                        try relationPrimitiveHook?(.beforeMaterialIsolation, staging)
                        try Task.checkCancellation()
                        try verifyRecord()
                        try verifyDirectories()
                        guard Darwin.renameatx_np(parent, location.name, isolation, "directory", UInt32(RENAME_EXCL)) == 0 else {
                            throw RelationLinkPrimitiveError.isolationFailed(errno)
                        }
                        settlement.observedIdentity = try nodeIdentity(descriptor: isolation, name: "directory")
                        try recordSettlement(settlement)
                        try relationPrimitiveHook?(.afterMaterialIsolation, isolated)
                        try synchronize(parent)
                        try synchronize(isolation)
                    }
                    // Unknown replacements stay at their actual isolation location, without restoration.
                    guard try nodeIdentity(descriptor: isolation, name: "directory") == creation.stagingDirectoryIdentity else {
                        throw RelationLinkPrimitiveError.replacementRetained
                    }
                    try relationPrimitiveHook?(.beforeMaterialRemoval, isolated)
                    try Task.checkCancellation()
                    try verifyRecord()
                    try verifyDirectories()
                    guard try nodeIdentity(descriptor: isolation, name: "directory") == creation.stagingDirectoryIdentity,
                          try descriptorIdentity(node) == creation.stagingDirectoryIdentity,
                          try directoryIsEmpty(node) else {
                        throw RelationLinkPrimitiveError.isolationChanged
                    }
                    // Only this private namespace is eligible. ENOTEMPTY also protects late contents.
                    guard Darwin.unlinkat(isolation, "directory", AT_REMOVEDIR) == 0 else {
                        throw RelationLinkPrimitiveError.removalFailed(errno)
                    }
                    try relationPrimitiveHook?(.afterMaterialRemoval, isolated)
                    try synchronize(isolation)
                    try verifyDirectories()
                    guard try nodeIdentity(descriptor: isolation, name: "directory") == nil else {
                        throw RelationLinkPrimitiveError.isolationChanged
                    }
                    settlement.status = .settled
                    settlement.observedIdentity = creation.stagingDirectoryIdentity
                    try recordSettlement(settlement)
                }
            }
        }
    }

    private func nodeIdentity(descriptor: Int32, name: String) throws -> LinkNodeIdentity? {
        var status = stat()
        if Darwin.fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 { return LinkNodeIdentity(status) }
        if errno == ENOENT { return nil }
        throw RelationLinkPrimitiveError.parentUnavailable(errno)
    }

    private func directoryIsEmpty(_ descriptor: Int32) throws -> Bool {
        let copy = Darwin.dup(descriptor)
        guard copy >= 0 else { throw RelationLinkPrimitiveError.parentUnavailable(errno) }
        guard let stream = Darwin.fdopendir(copy) else {
            Darwin.close(copy)
            throw RelationLinkPrimitiveError.parentUnavailable(errno)
        }
        defer { Darwin.closedir(stream) }
        Darwin.rewinddir(stream)
        errno = 0
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { return false }
        }
        guard errno == 0 else { throw RelationLinkPrimitiveError.parentUnavailable(errno) }
        return true
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
