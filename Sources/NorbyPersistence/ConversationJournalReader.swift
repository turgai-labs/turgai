import NorbyDomain

/// Concrete file-backed reader for Norby conversation journals.
///
/// This is a read model used during application startup. It is separate from
/// `FileEventStore`: the latter is the adapter installed into the cluster
/// journal plugin, while this value composes the same persistence client for a
/// one-shot recovery query.
public struct ConversationJournalReader: Sendable {
    private let client: FilePersistenceClient

    public init(client: FilePersistenceClient) {
        self.client = client
    }

    public func conversationJournals() async throws -> [ConversationJournal] {
        let persistenceIDs = try client.persistenceIDs(
            withPrefix: ConversationPersistenceID.prefix
        )
        var journals: [ConversationJournal] = []
        journals.reserveCapacity(persistenceIDs.count)

        for persistenceID in persistenceIDs {
            guard let conversationPersistenceID = ConversationPersistenceID(
                rawValue: persistenceID
            ) else {
                continue
            }

            let events: [ConversationEvent] = try await client.events(
                for: conversationPersistenceID.rawValue
            )
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
