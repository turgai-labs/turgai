import Distributed
import DistributedCluster
import EventSourcing
import SQLiteNIO
import TurgaiDomain
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension EventTag {
    /// What the conversation directory is kept from: each conversation's start, people, title, and
    /// each time something's said in it.
    public static let conversation = EventTag("conversation")
}

public enum ConversationDirectoryError: Error, Equatable, Sendable {
    /// A journal that isn't a conversation's.
    case notAConversation(PersistenceID)
    /// A kept row that isn't a conversation's.
    case invalidEntry
}

/// A conversation a person is in, as their list shows it: what it's called, where it is, and the
/// agent that answers it.
public struct ConversationListing: Hashable, Codable, Sendable {
    public let id: ConversationID
    public let space: SpaceID
    /// The agent that answers in it.
    public let agent: AgentProfileID
    /// Its title, or else the first line of the first thing said in it: none until either.
    public let title: String?

    public init(id: ConversationID, space: SpaceID, agent: AgentProfileID, title: String?) {
        self.id = id
        self.space = space
        self.agent = agent
        self.title = title
    }
}

/// What one of a conversation's events changes in the directory. Each leaves the directory as it
/// is when it's kept a second time.
public enum ConversationDirectoryChange: Hashable, Sendable {
    case started(ConversationID, in: SpaceID)
    case joined(ConversationID, Participant)
    case left(ConversationID, Participant)
    case titled(ConversationID, ConversationTitle)
    /// Something was said in it: `firstLine` is the first line of a person's words, none for its
    /// agent's.
    case said(ConversationID, firstLine: String?)

    /// What `event`, the conversation `conversation`'s, changes: none for what the directory
    /// doesn't show.
    public init?(_ event: ConversationEvent, in conversation: ConversationID) {
        switch event {
        case .started(let space): self = .started(conversation, in: space)
        case .joined(let participant): self = .joined(conversation, participant)
        case .left(let participant): self = .left(conversation, participant)
        case .titled(let title): self = .titled(conversation, title)
        case .inbox(.queued(let pending)), .inbox(.turnStarted(let pending)):
            let line = pending.message.text.split(whereSeparator: \.isNewline).lazy.map { String($0).trimmed() }
                .first { !$0.isEmpty }
            self = .said(conversation, firstLine: line.map { String($0.prefix(ConversationTitle.maximumLength)) })
        case .replyQueued: self = .said(conversation, firstLine: nil)
        case .inbox(.turnCompleted), .inbox(.turnFailed), .awaiting, .answered, .replyDelivered, .reset, .noted,
            .unnoted:
            return nil
        }
    }
}

/// Where the conversation directory is kept: the conversations each person is in, the ones on
/// each channel, and how far into the conversations' events it's read.
public struct ConversationDirectoryStorage: Sendable {
    /// The conversations the person is in, the one something was last said in first.
    public var conversations: @Sendable (UserID) async throws -> [ConversationListing]
    /// The conversations on a channel.
    public var onChannel: @Sendable (ChannelID) async throws -> [ConversationID]
    /// Where it's read the conversations' events up to.
    public var offset: @Sendable () async throws -> Offset
    /// Keeps a change, kept at an offset, then that it's read up to it.
    public var keep: @Sendable (ConversationDirectoryChange?, Offset) async throws -> Void

    public init(
        conversations: @escaping @Sendable (UserID) async throws -> [ConversationListing],
        onChannel: @escaping @Sendable (ChannelID) async throws -> [ConversationID],
        offset: @escaping @Sendable () async throws -> Offset,
        keep: @escaping @Sendable (ConversationDirectoryChange?, Offset) async throws -> Void
    ) {
        self.conversations = conversations
        self.onChannel = onChannel
        self.offset = offset
        self.keep = keep
    }

    /// The directory in Turgai's database, its tables made if they aren't there yet.
    public static func live(in persistence: TurgaiPersistence) async throws -> Self {
        let tables = try await ConversationDirectoryTables(in: persistence)
        return Self(
            conversations: { try await tables.conversations(of: $0) },
            onChannel: { try await tables.conversations(on: $0) },
            offset: { try await tables.offset() },
            keep: { try await tables.keep($0, at: $1) }
        )
    }

    /// A directory kept in memory, a new one each time.
    public static var test: Self {
        let directory = MemoryConversationDirectory()
        return Self(
            conversations: { await directory.conversations(of: $0) },
            onChannel: { await directory.conversations(on: $0) },
            offset: { await directory.offset },
            keep: { await directory.keep($0, at: $1) }
        )
    }
}

/// The directory in Turgai's database: each conversation's space, agent, title, first line and
/// when something was last said in it, the offset of that event; each person in a conversation;
/// and how far it's read. Each change is one write, and keeping it again changes nothing, so the
/// offset is kept after it.
private struct ConversationDirectoryTables: Sendable {
    // Held, not only its connection: the connection stays open while the tables are used.
    private let persistence: TurgaiPersistence
    private var connection: SQLiteConnection { persistence.connection }
    /// What it's known by among the read sides kept from the journal.
    private static let projection = "conversation-directory"

    init(in persistence: TurgaiPersistence) async throws {
        self.persistence = persistence
        for statement in [
            """
            CREATE TABLE IF NOT EXISTS conversation_listings (
                conversation TEXT    NOT NULL PRIMARY KEY,
                channel      TEXT    NOT NULL,
                space        TEXT    NOT NULL,
                agent        TEXT,
                title        TEXT,
                first_line   TEXT,
                latest       INTEGER NOT NULL
            ) WITHOUT ROWID
            """,
            """
            CREATE TABLE IF NOT EXISTS conversation_people (
                person       TEXT NOT NULL,
                conversation TEXT NOT NULL,
                PRIMARY KEY (person, conversation)
            ) WITHOUT ROWID
            """,
            """
            CREATE TABLE IF NOT EXISTS projection_offsets (
                projection TEXT    NOT NULL PRIMARY KEY,
                read_up_to INTEGER NOT NULL
            ) WITHOUT ROWID
            """,
        ] {
            _ = try await connection.query(statement)
        }
    }

    func conversations(of person: UserID) async throws -> [ConversationListing] {
        try await connection.query(
            """
            SELECT conversation_listings.conversation, space, agent, COALESCE(title, first_line) AS called
            FROM conversation_people
            JOIN conversation_listings ON conversation_listings.conversation = conversation_people.conversation
            WHERE person = ? AND agent IS NOT NULL ORDER BY latest DESC
            """,
            [.text(person.key)]
        ).map { row in
            guard let conversation = row.column("conversation")?.string.flatMap(ConversationID.init(stableKey:)),
                let space = row.column("space")?.string.flatMap(UUID.init(uuidString:)),
                let agent = row.column("agent")?.string
            else { throw ConversationDirectoryError.invalidEntry }
            return ConversationListing(
                id: conversation, space: SpaceID(rawValue: space), agent: AgentProfileID(agent),
                title: row.column("called")?.string)
        }
    }

    func conversations(on channel: ChannelID) async throws -> [ConversationID] {
        try await connection.query(
            "SELECT conversation FROM conversation_listings WHERE channel = ?", [.text(channel.rawValue)]
        ).map { row in
            guard let conversation = row.column("conversation")?.string.flatMap(ConversationID.init(stableKey:))
            else { throw ConversationDirectoryError.invalidEntry }
            return conversation
        }
    }

    func offset() async throws -> Offset {
        let row = try await connection.query(
            "SELECT read_up_to FROM projection_offsets WHERE projection = ?", [.text(Self.projection)]
        ).first
        return Offset(Int64(row?.column("read_up_to")?.integer ?? 0))
    }

    func keep(_ change: ConversationDirectoryChange?, at offset: Offset) async throws {
        switch change {
        case .started(let conversation, let space)?:
            _ = try await connection.query(
                """
                INSERT INTO conversation_listings (conversation, channel, space, latest) VALUES (?, ?, ?, ?)
                ON CONFLICT (conversation) DO NOTHING
                """,
                [
                    .text(conversation.stableKey), .text(conversation.channel.rawValue),
                    .text(space.rawValue.uuidString), .integer(Int(offset.rawValue)),
                ])
        case .joined(let conversation, .person(let person))?:
            _ = try await connection.query(
                "INSERT INTO conversation_people (person, conversation) VALUES (?, ?) ON CONFLICT DO NOTHING",
                [.text(person.key), .text(conversation.stableKey)])
        case .joined(let conversation, .agent(let agent))?:
            _ = try await connection.query(
                "UPDATE conversation_listings SET agent = ? WHERE conversation = ?",
                [.text(agent.rawValue), .text(conversation.stableKey)])
        case .left(let conversation, .person(let person))?:
            _ = try await connection.query(
                "DELETE FROM conversation_people WHERE person = ? AND conversation = ?",
                [.text(person.key), .text(conversation.stableKey)])
        case .left(let conversation, .agent(let agent))?:
            _ = try await connection.query(
                "UPDATE conversation_listings SET agent = NULL WHERE conversation = ? AND agent = ?",
                [.text(conversation.stableKey), .text(agent.rawValue)])
        case .titled(let conversation, let title)?:
            _ = try await connection.query(
                "UPDATE conversation_listings SET title = ? WHERE conversation = ?",
                [.text(title.rawValue), .text(conversation.stableKey)])
        case .said(let conversation, let firstLine)?:
            _ = try await connection.query(
                """
                UPDATE conversation_listings
                SET first_line = COALESCE(first_line, ?), latest = MAX(latest, ?)
                WHERE conversation = ?
                """,
                [firstLine.map(SQLiteData.text) ?? .null, .integer(Int(offset.rawValue)), .text(conversation.stableKey)])
        case nil:
            break
        }
        _ = try await connection.query(
            """
            INSERT INTO projection_offsets (projection, read_up_to) VALUES (?, ?)
            ON CONFLICT (projection) DO UPDATE SET read_up_to = excluded.read_up_to
            """,
            [.text(Self.projection), .integer(Int(offset.rawValue))])
    }
}

/// The directory of ``ConversationDirectoryStorage/test``.
private actor MemoryConversationDirectory {
    private struct Listing {
        let space: SpaceID
        var agent: AgentProfileID?
        var title: ConversationTitle?
        var firstLine: String?
        var latest: Offset
    }

    private var listings: [ConversationID: Listing] = [:]
    private var people: [UserID: Set<ConversationID>] = [:]
    private(set) var offset = Offset.start

    func conversations(of person: UserID) -> [ConversationListing] {
        (people[person] ?? []).compactMap { id in listings[id].map { (id, $0) } }
            .sorted { $0.1.latest > $1.1.latest }
            .compactMap { id, listing in
                listing.agent.map {
                    ConversationListing(
                        id: id, space: listing.space, agent: $0, title: listing.title?.rawValue ?? listing.firstLine)
                }
            }
    }

    func conversations(on channel: ChannelID) -> [ConversationID] {
        listings.keys.filter { $0.channel == channel }
    }

    func keep(_ change: ConversationDirectoryChange?, at offset: Offset) {
        switch change {
        case .started(let conversation, let space)?:
            if listings[conversation] == nil { listings[conversation] = Listing(space: space, latest: offset) }
        case .joined(let conversation, .person(let person))?:
            people[person, default: []].insert(conversation)
        case .joined(let conversation, .agent(let agent))?:
            listings[conversation]?.agent = agent
        case .left(let conversation, .person(let person))?:
            people[person]?.remove(conversation)
        case .left(let conversation, .agent(let agent))?:
            if listings[conversation]?.agent == agent { listings[conversation]?.agent = nil }
        case .titled(let conversation, let title)?:
            listings[conversation]?.title = title
        case .said(let conversation, let firstLine)?:
            if listings[conversation]?.firstLine == nil { listings[conversation]?.firstLine = firstLine }
            if let latest = listings[conversation]?.latest { listings[conversation]?.latest = max(latest, offset) }
        case nil:
            break
        }
        self.offset = offset
    }
}

/// The conversations each person is in, kept from every conversation's events: one in the
/// cluster, run where the journal can be read, as its projection must be.
public distributed actor ConversationDirectory: ClusterSingleton {
    public typealias ActorSystem = ClusterSystem

    /// What the cluster knows it by.
    public static let singletonName = "turgai-conversation-directory"

    private let storage: ConversationDirectoryStorage
    /// The journal the conversations' events are read from: the concrete store, on this node.
    private let journal: any EventStore
    private let refreshInterval: Duration
    /// The projection, while it's the cluster's directory.
    private var following: Task<Void, Never>?

    /// A directory kept in `storage`, from the conversations' events in `journal`, read again
    /// every `refreshInterval` once it's caught up.
    public init(
        actorSystem: ClusterSystem,
        storage: ConversationDirectoryStorage,
        journal: any EventStore,
        refreshInterval: Duration = .seconds(1)
    ) {
        self.actorSystem = actorSystem
        self.storage = storage
        self.journal = journal
        self.refreshInterval = refreshInterval
    }

    /// The conversations `person` is in, the one something was last said in first.
    public distributed func conversations(of person: UserID) async throws -> [ConversationListing] {
        try await storage.conversations(person)
    }

    /// The conversations on `channel`.
    public distributed func conversations(on channel: ChannelID) async throws -> [ConversationID] {
        try await storage.onChannel(channel)
    }

    /// Follows the conversations' events while it's the cluster's directory: from where it read up
    /// to, and again from there whenever following them fails.
    public func activateSingleton() async {
        let storage = storage
        let projection = Projection<ConversationEvent>(tag: .conversation, offset: { try await storage.offset() }) {
            envelope in
            guard let conversation = ConversationPersistenceID(rawValue: envelope.persistenceID)?.conversationID else {
                throw ConversationDirectoryError.notAConversation(envelope.persistenceID)
            }
            try await storage.keep(ConversationDirectoryChange(envelope.event, in: conversation), envelope.offset)
        }
        let journal = journal
        let refreshInterval = refreshInterval
        let log = actorSystem.log
        following = Task {
            await projection.runRestarting(on: journal, refreshInterval: refreshInterval) { error in
                log.error(
                    "The conversation directory failed to follow the conversations' events; it starts again shortly",
                    metadata: ["error": .string(String(describing: error))])
            }
        }
    }

    public func passivateSingleton() async {
        following?.cancel()
        following = nil
    }
}
