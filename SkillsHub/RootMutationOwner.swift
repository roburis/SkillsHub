import Darwin
import Foundation

/// Outcome of requesting the cross-process write qualification for a Root.
///
/// `.performed` carries the operation result once the qualification was held for the whole
/// operation. `.writeUnavailable` means another live process already holds the lock: the caller
/// stays read-only and is told why, matching the single-writer contract.
nonisolated enum RootWriteQualification<Success>: Sendable where Success: Sendable {
    case performed(Success)
    case writeUnavailable(RootWriteUnavailableReason)
}

extension RootWriteQualification: Equatable where Success: Equatable {}

nonisolated enum RootWriteUnavailableReason: Error, Equatable, Sendable {
    /// Another SkillsHub process currently holds the write qualification for this Root.
    case heldByAnotherProcess
    /// The lock file could not be opened inside the authorized Root (e.g. permission loss).
    case lockUnavailable(errno: Int32)
}

/// A process-level advisory lock on a Root's dedicated lock file.
///
/// Uses `flock(LOCK_EX | LOCK_NB)` on an fd opened against `RootLayout.writeLockFile`. The lock is
/// released when the fd is closed and, crucially, automatically by the kernel when the owning
/// process exits — so a crashed holder never wedges the Root, and re-acquisition never relies on
/// guessing from timestamps. The lock node is independent of the `.skillshub.json` node that commits
/// replace, so publishing metadata cannot drop the qualification.
nonisolated final class RootProcessWriteLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Attempts to acquire the exclusive lock without blocking.
    ///
    /// Returns `.lockUnavailable` when the lock file cannot be opened, and throws
    /// `RootWriteUnavailableReason.heldByAnotherProcess` (as a thrown reason) is avoided; instead the
    /// result distinguishes a live holder (`nil`) from an open failure.
    static func acquire(at lockFile: URL) -> Result<RootProcessWriteLock, RootWriteUnavailableReason> {
        let descriptor = lockFile.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else { return -1 }
            return open(pointer, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else {
            return .failure(.lockUnavailable(errno: errno))
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            close(descriptor)
            if failure == EWOULDBLOCK {
                return .failure(.heldByAnotherProcess)
            }
            return .failure(.lockUnavailable(errno: failure))
        }
        return .success(RootProcessWriteLock(descriptor: descriptor))
    }

    /// Releases the lock. Closing the fd drops the advisory lock; the kernel would also drop it on
    /// process exit, so this is the normal in-process release path.
    func release() {
        // flock(LOCK_UN) then close; close alone releases, but unlocking first keeps the fd state clear.
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

actor RootMutationOwner {
    static let shared = RootMutationOwner()

    private let metadataStore: SkillsHubMetadataStore
    private var activeRoots: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    #if DEBUG
    private var contentionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    #endif

    init(metadataStore: SkillsHubMetadataStore = SkillsHubMetadataStore()) {
        self.metadataStore = metadataStore
    }

    func perform<Result>(
        at rootURL: URL,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        let rootKey = key(for: rootURL)
        await acquire(rootKey)
        do {
            let result = try await operation()
            release(rootKey)
            return result
        } catch {
            release(rootKey)
            throw error
        }
    }

    /// Serializes same-Root writers in-process (existing queue) and additionally holds the
    /// cross-process write qualification for the whole operation.
    ///
    /// If another live process holds the lock, the operation does not run and the caller receives
    /// `.writeUnavailable` so it can stay read-only. The lock (and the in-process slot) is released on
    /// every exit path — success, thrown error, or cancellation.
    func withWriteQualification<Success: Sendable>(
        at rootURL: URL,
        operation: () async throws -> Success
    ) async rethrows -> RootWriteQualification<Success> {
        let rootKey = key(for: rootURL)
        let lockFile = metadataStore.rootLayout(for: rootURL).writeLockFile
        await acquire(rootKey)
        let lock: RootProcessWriteLock
        switch RootProcessWriteLock.acquire(at: lockFile) {
        case .success(let acquired):
            lock = acquired
        case .failure(let reason):
            release(rootKey)
            return .writeUnavailable(reason)
        }
        do {
            let result = try await operation()
            lock.release()
            release(rootKey)
            return .performed(result)
        } catch {
            lock.release()
            release(rootKey)
            throw error
        }
    }

    #if DEBUG
    func waitUntilContendedForTesting(at rootURL: URL) async {
        let rootKey = key(for: rootURL)
        guard waiters[rootKey]?.isEmpty != false else { return }
        await withCheckedContinuation { continuation in
            contentionWaiters[rootKey, default: []].append(continuation)
        }
    }
    #endif

    private func acquire(_ rootKey: String) async {
        guard activeRoots.insert(rootKey).inserted == false else { return }
        await withCheckedContinuation { continuation in
            waiters[rootKey, default: []].append(continuation)
            #if DEBUG
            let observers = contentionWaiters.removeValue(forKey: rootKey) ?? []
            for observer in observers {
                observer.resume()
            }
            #endif
        }
    }

    private func release(_ rootKey: String) {
        guard var pending = waiters[rootKey], pending.isEmpty == false else {
            waiters[rootKey] = nil
            activeRoots.remove(rootKey)
            return
        }
        let next = pending.removeFirst()
        waiters[rootKey] = pending.isEmpty ? nil : pending
        next.resume()
    }

    private func key(for rootURL: URL) -> String {
        rootURL.standardizedFileURL.path
    }
}
