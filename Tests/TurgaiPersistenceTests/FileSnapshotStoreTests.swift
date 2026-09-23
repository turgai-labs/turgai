import EventSourcing
import Testing

@testable import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct FileSnapshotStoreTests {
    private struct TestState: Codable, Equatable, Sendable {
        let value: String
    }

    @Test
    func savesLoadsAndKeepsNewestSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turgai-file-snapshot-store-" + UUID().uuidString)
        let store = FileSnapshotStore(
            client: try FileClient(directory: directory)
        )

        try await store.save(
            TestState(value: "one"),
            id: "conversation:one",
            coveredSequenceNumber: 1
        )
        try await store.save(
            TestState(value: "replacement"),
            id: "conversation:one",
            coveredSequenceNumber: 1
        )
        try await store.save(
            TestState(value: "three"),
            id: "conversation:one",
            coveredSequenceNumber: 3
        )
        try await store.save(
            TestState(value: "two"),
            id: "conversation:one",
            coveredSequenceNumber: 2
        )

        let snapshot: Snapshot<TestState>? = try await store.latestSnapshot(
            id: "conversation:one"
        )
        #expect(snapshot?.coveredSequenceNumber == 3)
        #expect(snapshot?.state == TestState(value: "three"))
    }

    @Test
    func deletesSnapshotsMatchingCriteria() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turgai-file-snapshot-store-" + UUID().uuidString)
        let store = FileSnapshotStore(
            client: try FileClient(directory: directory)
        )

        for sequenceNumber in 1...3 {
            try await store.save(
                TestState(value: "\(sequenceNumber)"),
                id: "user:one",
                coveredSequenceNumber: Int64(sequenceNumber)
            )
        }

        try await store.deleteSnapshots(
            id: "user:one",
            matching: .init(minSequenceNumber: 1, maxSequenceNumber: 2)
        )

        let snapshot: Snapshot<TestState>? = try await store.latestSnapshot(id: "user:one")
        #expect(snapshot?.coveredSequenceNumber == 3)
        #expect(snapshot?.state == TestState(value: "3"))

        try await store.deleteSnapshots(id: "user:one", matching: .through(3))
        let deleted: Snapshot<TestState>? = try await store.latestSnapshot(id: "user:one")
        #expect(deleted == nil)
    }

    @Test
    func missingSnapshotIsEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turgai-file-snapshot-store-" + UUID().uuidString)
        let store = FileSnapshotStore(
            client: try FileClient(directory: directory)
        )

        let snapshot: Snapshot<TestState>? = try await store.latestSnapshot(id: "missing")
        #expect(snapshot == nil)
    }
}
