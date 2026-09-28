import Foundation
import CoreServices

/// Dirty scope reported by filesystem observation.
///
/// Events only mark a scope dirty and trigger a recheck; they never directly add,
/// remove, or change enablement. Path→scope mapping is owned by
/// ``FilesystemObservationController``.
nonisolated enum ObservationScope: Hashable, Sendable {
    /// The managed content under the SkillsHub Root (`local/`, `github/`, metadata).
    case managedRoot
    /// A single authorized Agent skills directory, keyed by its Agent id.
    case agentDirectory(agentID: String)
}

/// Mirror of the `kFSEventStreamEventFlag*` bits this service reasons about.
///
/// Only the flags that change recheck behavior are modeled; the raw stream may
/// carry more that are intentionally ignored.
nonisolated struct FilesystemEventFlags: OptionSet, Sendable {
    let rawValue: UInt32

    init(rawValue: UInt32) { self.rawValue = rawValue }

    static let mustScanSubDirs = FilesystemEventFlags(rawValue: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
    static let userDropped = FilesystemEventFlags(rawValue: UInt32(kFSEventStreamEventFlagUserDropped))
    static let kernelDropped = FilesystemEventFlags(rawValue: UInt32(kFSEventStreamEventFlagKernelDropped))
    static let rootChanged = FilesystemEventFlags(rawValue: UInt32(kFSEventStreamEventFlagRootChanged))
    static let mount = FilesystemEventFlags(rawValue: UInt32(kFSEventStreamEventFlagMount))
    static let unmount = FilesystemEventFlags(rawValue: UInt32(kFSEventStreamEventFlagUnmount))

    /// The batch cannot be trusted for a scoped delta and needs a full authorized scan.
    var forcesFullScan: Bool {
        !isDisjoint(with: [.mustScanSubDirs, .userDropped, .kernelDropped])
    }

    /// The watched Root itself moved/was replaced or a volume changed underneath it.
    var indicatesRootChange: Bool {
        !isDisjoint(with: [.rootChanged, .mount, .unmount])
    }
}

/// One raw event delivered by the underlying stream before scope mapping.
nonisolated struct FilesystemRawEvent: Sendable {
    var path: String
    var flags: FilesystemEventFlags
    var eventID: UInt64

    init(path: String, flags: FilesystemEventFlags, eventID: UInt64) {
        self.path = path
        self.flags = flags
        self.eventID = eventID
    }
}

/// A coalesced batch of raw events reduced to the scopes a recheck must cover.
nonisolated struct FilesystemEventBatch: Sendable, Equatable {
    /// Scopes touched by this batch and resolvable to a known watched location.
    var scopes: Set<ObservationScope>
    /// A trusted scoped delta is impossible; rescan the whole authorized range.
    var needsFullScan: Bool
    /// The Root moved/was replaced or a volume changed; treat as a root change.
    var rootChanged: Bool

    init(scopes: Set<ObservationScope> = [], needsFullScan: Bool = false, rootChanged: Bool = false) {
        self.scopes = scopes
        self.needsFullScan = needsFullScan
        self.rootChanged = rootChanged
    }

    var isEmpty: Bool {
        scopes.isEmpty && !needsFullScan && !rootChanged
    }
}

/// Lifecycle state of filesystem observation, surfaced to the UI so it can present an
/// explicit "unknown" when observation cannot be trusted.
///
/// Permission loss, a monitor failure, or a scan failure all resolve to
/// ``unavailable`` — the managed facts are then unknown until recovery re-subscribes
/// and re-scans. Pure success is ``observing``; before any subscription it is
/// ``notStarted``.
nonisolated enum ObservationLifecycleStatus: Equatable, Sendable {
    case notStarted
    case observing
    case unavailable(reason: Reason)

    enum Reason: Equatable, Sendable {
        /// The security-scoped permission to the Root or Agent directory was lost.
        case permissionLost
        /// The underlying event stream could not start or was dropped.
        case monitorFailed
        /// A recheck scan failed; the reflected facts may be stale.
        case scanFailed
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// Injectable underlying event stream. Production uses ``SystemFilesystemEventStream``;
/// tests inject a fake that feeds synthetic ``FilesystemRawEvent`` batches.
nonisolated protocol FilesystemEventStreaming: AnyObject {
    /// Starts watching `paths`. Returns whether the stream successfully started.
    /// `onBatch` is invoked on an unspecified queue with each raw batch.
    func start(
        paths: [String],
        onBatch: @escaping @Sendable ([FilesystemRawEvent]) -> Void
    ) -> Bool

    /// Stops and releases the stream. Safe to call more than once.
    func stop()
}

/// Inert stream used as the default outside the real app entry point (e.g. in unit
/// tests that construct a controller directly). It reports a successful start so
/// observation is nominally active, but never watches the filesystem and never
/// delivers events — keeping tests deterministic and free of real FSEvents. Tests that
/// need to drive events inject a fake; the app injects ``SystemFilesystemEventStream``.
nonisolated final class InertFilesystemEventStream: FilesystemEventStreaming {
    private let startResult: Bool

    init(startResult: Bool = true) {
        self.startResult = startResult
    }

    func start(
        paths: [String],
        onBatch: @escaping @Sendable ([FilesystemRawEvent]) -> Void
    ) -> Bool {
        startResult
    }

    func stop() {}
}

/// Production adapter over the FSEvents C API.
///
/// Uses a dedicated serial dispatch queue for callbacks. The C callback is a bare
/// function pointer, so the Swift closure is bridged through the stream `info`
/// pointer via `Unmanaged`. The instance owns exactly one live stream at a time.
nonisolated final class SystemFilesystemEventStream: FilesystemEventStreaming {
    private let latency: CFTimeInterval
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var streamRef: FSEventStreamRef?
    private var callbackBox: CallbackBox?

    /// Retained bridge holding the Swift closure the C callback forwards to.
    private final class CallbackBox {
        let onBatch: @Sendable ([FilesystemRawEvent]) -> Void
        init(_ onBatch: @escaping @Sendable ([FilesystemRawEvent]) -> Void) {
            self.onBatch = onBatch
        }
    }

    init(latency: CFTimeInterval = 0.3) {
        self.latency = latency
        self.queue = DispatchQueue(label: "com.skillshub.filesystem-observation", qos: .utility)
    }

    deinit {
        teardown()
    }

    func start(
        paths: [String],
        onBatch: @escaping @Sendable ([FilesystemRawEvent]) -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
        guard !paths.isEmpty else { return false }

        let box = CallbackBox(onBatch)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return false
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        streamRef = stream
        callbackBox = box
        return true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
    }

    private func teardown() {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
    }

    private func teardownLocked() {
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
        callbackBox = nil
    }

    private static let callback: FSEventStreamCallback = {
        _, info, count, eventPaths, eventFlags, eventIDs in
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
        var events: [FilesystemRawEvent] = []
        events.reserveCapacity(count)
        for index in 0..<count where index < paths.count {
            events.append(
                FilesystemRawEvent(
                    path: paths[index],
                    flags: FilesystemEventFlags(rawValue: eventFlags[index]),
                    eventID: eventIDs[index]
                )
            )
        }
        box.onBatch(events)
    }
}
