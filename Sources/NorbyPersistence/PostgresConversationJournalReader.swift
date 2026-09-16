import EventSourcing
import NorbyDomain
import PostgresEventStore
import PostgresNIO

/// Startup read model for conversation IDs stored in PostgreSQL.
///
/// The PostgreSQL event-store package intentionally exposes the event stream,
/// not a persistence-ID query. This reader owns that application-specific
/// query so Telegram restoration has the same behavior for both backends.
public struct PostgresConversationJournalReader: Sendable {
    private let client: PostgresClient
    private let eventStore: PostgresEventStore

    public init(client: PostgresClient, eventStore: PostgresEventStore) {
        self.client = client
        self.eventStore = eventStore
    }

    public func conversationJournals() async throws -> [ConversationJournal] {
        let persistencePrefix = "\(ConversationPersistenceID.prefix)%"
        let rows = try await client.query(
            """
            SELECT DISTINCT persistence_id
            FROM journal
            WHERE persistence_id LIKE \(persistencePrefix)
            ORDER BY persistence_id ASC
            """
        )

        var persistenceIDs: [String] = []
        for try await persistenceID in rows.decode(String.self) {
            persistenceIDs.append(persistenceID)
        }

        var journals: [ConversationJournal] = []
        journals.reserveCapacity(persistenceIDs.count)
        for persistenceID in persistenceIDs {
            guard let conversationPersistenceID = ConversationPersistenceID(rawValue: persistenceID) else {
                continue
            }
            let stream: EventStream<ConversationEvent> = try await eventStore.eventStream(
                id: persistenceID,
                fromSequenceNumber: 1
            )
            var events: [ConversationEvent] = []
            for try await envelope in stream {
                events.append(envelope.event)
            }
            journals.append(
                ConversationJournal(
                    conversationID: conversationPersistenceID.conversationID,
                    events: events
                )
            )
        }
        return journals
    }
}
