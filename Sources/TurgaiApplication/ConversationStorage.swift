import SQLiteNIO
import TurgaiDomain
import TurgaiPersistence

public enum ConversationStorageError: Error, Equatable, Sendable {
    /// A kept conversation that isn't one.
    case invalidConversation
}

/// Where the conversations there are kept: each once, from when it starts.
public struct ConversationStorage: Sendable {
    /// Keeps the conversation among the conversations, unless it's there already.
    public var add: @Sendable (ConversationID) async throws -> Void
    /// Every conversation, in the order they started.
    public var all: @Sendable () async throws -> [ConversationID]

    public init(
        add: @escaping @Sendable (ConversationID) async throws -> Void,
        all: @escaping @Sendable () async throws -> [ConversationID]
    ) {
        self.add = add
        self.all = all
    }

    /// The conversations in Turgai's database, their table made if it isn't there yet.
    public static func live(in persistence: TurgaiPersistence) async throws -> Self {
        let table = try await ConversationTable(in: persistence)
        return Self(add: { try await table.add($0) }, all: { try await table.all() })
    }

    /// Conversations kept in memory, a new place each time.
    public static var test: Self {
        let conversations = MemoryConversations()
        return Self(add: { await conversations.add($0) }, all: { await conversations.all() })
    }
}

/// The conversations in Turgai's database, a table of their own.
private struct ConversationTable: Sendable {
    // Held, not only its connection: the connection stays open while the table is used.
    private let persistence: TurgaiPersistence
    private var connection: SQLiteConnection { persistence.connection }

    /// The table in `persistence`, made if it isn't there yet.
    init(in persistence: TurgaiPersistence) async throws {
        self.persistence = persistence
        _ = try await connection.query(
            """
            CREATE TABLE IF NOT EXISTS conversations (
                channel          TEXT NOT NULL,
                external_address TEXT NOT NULL,
                started_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
                PRIMARY KEY (channel, external_address)
            ) WITHOUT ROWID
            """)
    }

    func add(_ conversation: ConversationID) async throws {
        _ = try await connection.query(
            "INSERT INTO conversations (channel, external_address) VALUES (?, ?) ON CONFLICT DO NOTHING",
            [.text(conversation.channel.rawValue), .text(conversation.externalAddress.rawValue)])
    }

    func all() async throws -> [ConversationID] {
        try await connection.query(
            "SELECT channel, external_address FROM conversations ORDER BY started_at, channel, external_address"
        ).map { row in
            guard let channel = row.column("channel")?.string,
                let address = row.column("external_address")?.string
            else { throw ConversationStorageError.invalidConversation }
            return ConversationID(channel: ChannelID(rawValue: channel), externalAddress: .init(rawValue: address))
        }
    }
}

/// The conversations of ``ConversationStorage/test``.
private actor MemoryConversations {
    private var conversations: [ConversationID] = []

    func add(_ conversation: ConversationID) {
        guard !conversations.contains(conversation) else { return }
        conversations.append(conversation)
    }

    func all() -> [ConversationID] {
        conversations
    }
}
