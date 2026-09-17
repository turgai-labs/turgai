import EventSourcing

/// SnapshotStore adapter used by the cluster journal plugin.
public actor FileSnapshotStore: SnapshotStore {
    private let client: FilePersistenceClient

    public init(client: FilePersistenceClient) {
        self.client = client
    }

    public func save<State: Codable & Sendable>(
        _ state: State,
        id: PersistenceID,
        coveredSequenceNumber: Int64
    ) async throws {
        try client.saveSnapshot(
            state,
            id: id,
            coveredSequenceNumber: coveredSequenceNumber
        )
    }

    public func deleteSnapshots(
        id: PersistenceID,
        matching criteria: SnapshotSelectionCriteria
    ) async throws {
        try client.deleteSnapshots(id: id, matching: criteria)
    }

    public func latestSnapshot<State: Codable & Sendable>(
        id: PersistenceID
    ) async throws -> Snapshot<State>? {
        try client.latestSnapshot(id: id)
    }
}
