import EventSourcing

/// EventStore adapter used by the cluster journal plugin.
public actor FileEventStore: EventStore {
    private let client: FilePersistenceClient

    public init(client: FilePersistenceClient) {
        self.client = client
    }

    public func persistEvent<Event: Codable & Sendable>(
        _ event: Event,
        id: String,
        sequenceNumber: Int64
    ) async throws {
        try client.persistEvent(event, id: id, sequenceNumber: sequenceNumber)
    }

    public func eventStream<Event: Codable & Sendable>(
        id: String,
        fromSequenceNumber: Int64
    ) async throws -> EventStream<Event> {
        try client.eventStream(
            id: id,
            fromSequenceNumber: fromSequenceNumber
        )
    }
}
