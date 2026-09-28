import Foundation

nonisolated private final class FilesystemObservationCallbackTarget: @unchecked Sendable {
    weak var controller: FilesystemObservationController?

    @MainActor
    init(_ controller: FilesystemObservationController) {
        self.controller = controller
    }

    @MainActor
    func deliver(
        _ rawEvents: [FilesystemRawEvent],
        subscription: FilesystemObservationController.Subscription
    ) {
        controller?.ingest(rawEvents, from: subscription)
    }
}

/// Owns the filesystem event stream, maps raw event paths to ``ObservationScope``,
/// coalesces a raw batch into a single ``FilesystemEventBatch``, and delivers it on
/// the MainActor so the controller can trigger a scoped recheck.
///
/// Lifecycle: a single subscription at a time. `subscribe` starts the stream first
/// (so the caller can scan afterwards without an event gap); `stop` tears it down.
@MainActor
final class FilesystemObservationController {
    struct Subscription: Equatable, Sendable {
        var rootURL: URL
        /// Authorized Agent skills directories, keyed by Agent id.
        var agentDirectories: [String: URL]

        init(rootURL: URL, agentDirectories: [String: URL]) {
            self.rootURL = rootURL.standardizedFileURL
            self.agentDirectories = agentDirectories.mapValues { $0.standardizedFileURL }
        }
    }

    private let streamFactory: () -> any FilesystemEventStreaming
    private var stream: (any FilesystemEventStreaming)?
    private var current: Subscription?
    private var onDirtyHandler: (@MainActor (FilesystemEventBatch) -> Void)?

    init(streamFactory: @escaping () -> any FilesystemEventStreaming = { SystemFilesystemEventStream() }) {
        self.streamFactory = streamFactory
    }

    var isObserving: Bool { current != nil }

    var currentSubscription: Subscription? { current }

    /// Starts observing `subscription`. Any previous subscription is stopped first.
    /// Returns whether the underlying stream started; on failure no subscription is
    /// retained and the caller should mark observation unavailable.
    @discardableResult
    func subscribe(
        _ subscription: Subscription,
        onDirty: @escaping @MainActor (FilesystemEventBatch) -> Void
    ) -> Bool {
        stop()
        let stream = streamFactory()
        let paths = watchedPaths(for: subscription)
        let callbackTarget = FilesystemObservationCallbackTarget(self)
        let started = stream.start(paths: paths) { rawEvents in
            // Delivered on the stream's own queue; hop to MainActor to reduce and dispatch.
            Task { @MainActor in
                callbackTarget.deliver(rawEvents, subscription: subscription)
            }
        }
        guard started else {
            stream.stop()
            return false
        }
        self.stream = stream
        self.current = subscription
        self.onDirtyHandler = onDirty
        return true
    }

    /// Reduces a raw batch for `subscription` and, if it is still current and non-empty,
    /// dispatches it to the dirty handler. Shared by the production stream callback and
    /// the test injection path so both exercise identical coalescing and gating.
    fileprivate func ingest(_ rawEvents: [FilesystemRawEvent], from subscription: Subscription) {
        guard current == subscription, let onDirtyHandler else { return }
        let batch = reduce(rawEvents, for: subscription)
        guard !batch.isEmpty else { return }
        onDirtyHandler(batch)
    }

    /// Stops and releases the current subscription. Safe to call when idle.
    func stop() {
        stream?.stop()
        stream = nil
        current = nil
        onDirtyHandler = nil
    }

    #if DEBUG
    /// Feeds synthetic raw events through the exact production ingest path (reduce →
    /// gate → dispatch), for tests that drive scope dispatch and coalescing end to end.
    func injectForTesting(_ rawEvents: [FilesystemRawEvent]) {
        guard let current else { return }
        ingest(rawEvents, from: current)
    }
    #endif

    #if DEBUG
    /// Feeds synthetic raw events through the same reduction path as production,
    /// for tests that drive coalescing/loss/root-change/scope-mapping behavior.
    func reduceForTesting(
        _ rawEvents: [FilesystemRawEvent],
        subscription: Subscription? = nil
    ) -> FilesystemEventBatch {
        reduce(rawEvents, for: subscription ?? current ?? Subscription(rootURL: URL(fileURLWithPath: "/"), agentDirectories: [:]))
    }
    #endif

    private func watchedPaths(for subscription: Subscription) -> [String] {
        // Watch the managed Root and each authorized Agent directory. External
        // original source folders are intentionally never watched.
        [subscription.rootURL.path] + subscription.agentDirectories.values.map(\.path)
    }

    /// Reduces a raw batch to scopes, ORing the full-scan / root-change signals.
    private func reduce(
        _ rawEvents: [FilesystemRawEvent],
        for subscription: Subscription
    ) -> FilesystemEventBatch {
        var scopes: Set<ObservationScope> = []
        var needsFullScan = false
        var rootChanged = false
        for event in rawEvents {
            if event.flags.forcesFullScan { needsFullScan = true }
            if event.flags.indicatesRootChange { rootChanged = true }
            if let scope = scope(forPath: event.path, subscription: subscription) {
                scopes.insert(scope)
            }
        }
        return FilesystemEventBatch(scopes: scopes, needsFullScan: needsFullScan, rootChanged: rootChanged)
    }

    /// Maps a raw event path to its owning scope by path containment. An Agent
    /// directory match wins over the Root when both would contain the path.
    private func scope(forPath rawPath: String, subscription: Subscription) -> ObservationScope? {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        for (agentID, directory) in subscription.agentDirectories where isContained(path, in: directory.path) {
            return .agentDirectory(agentID: agentID)
        }
        if isContained(path, in: subscription.rootURL.path) {
            return .managedRoot
        }
        return nil
    }

    private func isContained(_ path: String, in directory: String) -> Bool {
        if path == directory { return true }
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(prefix)
    }
}
