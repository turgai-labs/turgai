import PostgresNIO
import TurgaiDomain

/// Read-side queries over PostgreSQL's event journal.
/// The event-store adapter owns appends and replay; this reader handles
/// persistence-ID discovery needed for actor recovery and runtime startup.
public struct PostgresJournalReader: Sendable {
    private let client: PostgresClient

    public init(client: PostgresClient) {
        self.client = client
    }

    public func persistenceIDs(withPrefix prefix: String) async throws -> [String] {
        let pattern = "\(prefix)%"
        let rows = try await client.query(
            """
            SELECT DISTINCT persistence_id
            FROM journal
            WHERE persistence_id LIKE \(pattern)
            ORDER BY persistence_id ASC
            """
        )

        var ids: [String] = []
        for try await persistenceID in rows.decode(String.self) {
            ids.append(persistenceID)
        }
        return ids
    }

    public func conversationIDs() async throws -> [ConversationID] {
        try await persistenceIDs(withPrefix: ConversationPersistenceID.prefix)
            .compactMap { ConversationPersistenceID(rawValue: $0)?.conversationID }
    }
}
