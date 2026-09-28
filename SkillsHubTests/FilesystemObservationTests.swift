import Foundation
import CoreServices
import Testing
@testable import SkillsHub

@MainActor
struct FilesystemObservationTests {
    // MARK: - Scope mapping

    @Test func mapsRootAndAgentPathsToDistinctScopes() {
        let root = URL(fileURLWithPath: "/tmp/root", isDirectory: true)
        let codexDir = URL(fileURLWithPath: "/tmp/home/.codex/skills", isDirectory: true)
        let controller = FilesystemObservationController(streamFactory: { FakeFilesystemEventStream() })
        let subscription = FilesystemObservationController.Subscription(
            rootURL: root,
            agentDirectories: ["codex": codexDir]
        )

        let batch = controller.reduceForTesting(
            [
                event("/tmp/root/local/review/SKILL.md"),
                event("/tmp/home/.codex/skills/review"),
                event("/tmp/unrelated/file")
            ],
            subscription: subscription
        )

        #expect(batch.scopes == [.managedRoot, .agentDirectory(agentID: "codex")])
        #expect(batch.needsFullScan == false)
        #expect(batch.rootChanged == false)
    }

    @Test func agentDirectoryContainedInRootStillMapsToAgentScope() {
        // An Agent directory nested under the Root must win over .managedRoot.
        let root = URL(fileURLWithPath: "/tmp/root", isDirectory: true)
        let nestedAgent = URL(fileURLWithPath: "/tmp/root/agents/codex/skills", isDirectory: true)
        let controller = FilesystemObservationController(streamFactory: { FakeFilesystemEventStream() })
        let subscription = FilesystemObservationController.Subscription(
            rootURL: root,
            agentDirectories: ["codex": nestedAgent]
        )

        let batch = controller.reduceForTesting(
            [event("/tmp/root/agents/codex/skills/entry")],
            subscription: subscription
        )

        #expect(batch.scopes == [.agentDirectory(agentID: "codex")])
    }

    // MARK: - Coalescing / loss / root change

    @Test func multiplePathsInOneScopeCoalesceToOneScopeEntry() {
        let controller = FilesystemObservationController(streamFactory: { FakeFilesystemEventStream() })
        let subscription = FilesystemObservationController.Subscription(
            rootURL: URL(fileURLWithPath: "/tmp/root", isDirectory: true),
            agentDirectories: [:]
        )

        let batch = controller.reduceForTesting(
            [
                event("/tmp/root/local/a/SKILL.md"),
                event("/tmp/root/local/b/SKILL.md"),
                event("/tmp/root/local/c")
            ],
            subscription: subscription
        )

        #expect(batch.scopes == [.managedRoot])
    }

    @Test func droppedEventsForceFullScan() {
        let controller = FilesystemObservationController(streamFactory: { FakeFilesystemEventStream() })
        let subscription = FilesystemObservationController.Subscription(
            rootURL: URL(fileURLWithPath: "/tmp/root", isDirectory: true),
            agentDirectories: [:]
        )

        for rawFlag in [
            kFSEventStreamEventFlagMustScanSubDirs,
            kFSEventStreamEventFlagUserDropped,
            kFSEventStreamEventFlagKernelDropped
        ] {
            let batch = controller.reduceForTesting(
                [event("/tmp/root/local/a", flags: FilesystemEventFlags(rawValue: UInt32(rawFlag)))],
                subscription: subscription
            )
            #expect(batch.needsFullScan == true)
        }
    }

    @Test func rootChangeFlagsAreReported() {
        let controller = FilesystemObservationController(streamFactory: { FakeFilesystemEventStream() })
        let subscription = FilesystemObservationController.Subscription(
            rootURL: URL(fileURLWithPath: "/tmp/root", isDirectory: true),
            agentDirectories: [:]
        )

        for rawFlag in [
            kFSEventStreamEventFlagRootChanged,
            kFSEventStreamEventFlagMount,
            kFSEventStreamEventFlagUnmount
        ] {
            let batch = controller.reduceForTesting(
                [event("/tmp/root", flags: FilesystemEventFlags(rawValue: UInt32(rawFlag)))],
                subscription: subscription
            )
            #expect(batch.rootChanged == true)
        }
    }

    // MARK: - Subscription lifecycle

    @Test func subscribeStartsStreamOnceAndStopTearsDown() {
        let stream = FakeFilesystemEventStream()
        let controller = FilesystemObservationController(streamFactory: { stream })
        let subscription = FilesystemObservationController.Subscription(
            rootURL: URL(fileURLWithPath: "/tmp/root", isDirectory: true),
            agentDirectories: ["codex": URL(fileURLWithPath: "/tmp/home/.codex/skills", isDirectory: true)]
        )

        let started = controller.subscribe(subscription) { _ in }

        #expect(started)
        #expect(controller.isObserving)
        #expect(stream.startCount == 1)
        #expect(Set(stream.startedPaths) == ["/tmp/root", "/tmp/home/.codex/skills"])

        controller.stop()
        #expect(!controller.isObserving)
        #expect(stream.stopCount >= 1)
    }

    @Test func failedStreamStartLeavesNoSubscription() {
        let stream = FakeFilesystemEventStream(allowsStart: false)
        let controller = FilesystemObservationController(streamFactory: { stream })
        let subscription = FilesystemObservationController.Subscription(
            rootURL: URL(fileURLWithPath: "/tmp/root", isDirectory: true),
            agentDirectories: [:]
        )

        let started = controller.subscribe(subscription) { _ in }

        #expect(!started)
        #expect(!controller.isObserving)
        #expect(stream.stopCount >= 1)
    }

    @Test func resubscribeStopsPreviousStream() {
        var streams: [FakeFilesystemEventStream] = []
        let controller = FilesystemObservationController(streamFactory: {
            let stream = FakeFilesystemEventStream()
            streams.append(stream)
            return stream
        })
        let first = FilesystemObservationController.Subscription(
            rootURL: URL(fileURLWithPath: "/tmp/root-a", isDirectory: true),
            agentDirectories: [:]
        )
        let second = FilesystemObservationController.Subscription(
            rootURL: URL(fileURLWithPath: "/tmp/root-b", isDirectory: true),
            agentDirectories: [:]
        )

        controller.subscribe(first) { _ in }
        controller.subscribe(second) { _ in }

        #expect(streams.count == 2)
        #expect(streams[0].stopCount >= 1)
        #expect(controller.currentSubscription == second)
    }

    // MARK: - Helpers

    private func event(_ path: String, flags: FilesystemEventFlags = []) -> FilesystemRawEvent {
        FilesystemRawEvent(path: path, flags: flags, eventID: 0)
    }
}

final class FakeFilesystemEventStream: FilesystemEventStreaming, @unchecked Sendable {
    let allowsStart: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var startedPaths: [String] = []
    private var onBatch: (@Sendable ([FilesystemRawEvent]) -> Void)?

    init(allowsStart: Bool = true) {
        self.allowsStart = allowsStart
    }

    func start(
        paths: [String],
        onBatch: @escaping @Sendable ([FilesystemRawEvent]) -> Void
    ) -> Bool {
        startCount += 1
        startedPaths = paths
        guard allowsStart else { return false }
        self.onBatch = onBatch
        return true
    }

    func stop() {
        stopCount += 1
        onBatch = nil
    }

    /// Emits a synthetic batch through the started callback.
    func emit(_ events: [FilesystemRawEvent]) {
        onBatch?(events)
    }
}
