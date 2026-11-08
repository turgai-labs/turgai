import Distributed
import DistributedCluster
import EventSourcing
import SQLiteNIO
import TurgaiDomain
import TurgaiMemory
import TurgaiPeople
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// One of a person's conversations with exchanges not read yet for their memory: its latest, the
/// agent that answered it, and when it was said.
public struct UnreadConversation: Hashable, Sendable {
    public let person: UserID
    public let conversation: ConversationID
    public let latest: MemorySourceID
    /// The latest exchange's message id in the channel it came through, to mark it there.
    public let channelMessageID: ChannelMessageID?
    /// The agent that answered it, whose model reads it.
    public let heardBy: AgentProfileID
    public let saidAt: Date

    public init(
        person: UserID, conversation: ConversationID, latest: MemorySourceID, channelMessageID: ChannelMessageID?,
        heardBy: AgentProfileID, saidAt: Date
    ) {
        self.person = person
        self.conversation = conversation
        self.latest = latest
        self.channelMessageID = channelMessageID
        self.heardBy = heardBy
        self.saidAt = saidAt
    }

    /// When it's read: once its person has been quiet for `quiet` after its latest exchange.
    public func due(after quiet: Duration) -> Date {
        saidAt.addingTimeInterval(TimeInterval(quiet.components.seconds))
    }
}

/// What one of a person's memory events changes in what's unread of their conversations. Each
/// leaves it as it is when it's kept a second time.
public enum UnreadMemoryChange: Hashable, Sendable {
    /// An exchange in one of their conversations: it's the latest there.
    case said(UnreadConversation)
    /// One of their conversations was read through an exchange: nothing's unread there when it
    /// was the latest.
    case read(UserID, ConversationID, through: MemorySourceID)
    /// Everything they said was forgotten.
    case forgotten(UserID)

    /// What `event`, `person`'s, changes: none for what doesn't touch what's unread.
    public init?(_ event: UserEvent, of person: UserID) {
        switch event {
        case .memory(.observationRecorded(let exchange)):
            self = .said(
                UnreadConversation(
                    person: person, conversation: exchange.conversation, latest: exchange.sourceID,
                    channelMessageID: exchange.channelMessageID, heardBy: exchange.heardBy,
                    saidAt: exchange.observedAt))
        case .memory(.extractionCommitted(let commit)):
            self = .read(person, commit.conversation, through: commit.readThrough)
        case .memory(.cleared):
            self = .forgotten(person)
        case .memory(.factForgotten), .memory(.rememberingChanged):
            return nil
        }
    }
}

public enum UnreadMemoryError: Error, Equatable, Sendable {
    /// A journal that isn't a person's.
    case notAPerson(PersistenceID)
    /// A kept row that isn't an unread conversation.
    case invalidEntry
}

/// Where what's unread is kept: each person's conversations with exchanges not read yet, and how
/// far into their memory events it's read.
public struct UnreadMemoryStorage: Sendable {
    /// Every conversation with something unread.
    public var unread: @Sendable () async throws -> [UnreadConversation]
    /// Where it's read the memory events up to.
    public var offset: @Sendable () async throws -> Offset
    /// Keeps a change, kept at an offset, then that it's read up to it.
    public var keep: @Sendable (UnreadMemoryChange?, Offset) async throws -> Void

    public init(
        unread: @escaping @Sendable () async throws -> [UnreadConversation],
        offset: @escaping @Sendable () async throws -> Offset,
        keep: @escaping @Sendable (UnreadMemoryChange?, Offset) async throws -> Void
    ) {
        self.unread = unread
        self.offset = offset
        self.keep = keep
    }

    /// What's unread, in Turgai's database, its tables made if they aren't there yet.
    public static func live(in persistence: TurgaiPersistence) async throws -> Self {
        let tables = try await UnreadMemoryTables(in: persistence)
        return Self(
            unread: { try await tables.unread() },
            offset: { try await tables.offset() },
            keep: { try await tables.keep($0, at: $1) }
        )
    }

    /// What's unread, kept in memory, a new one each time.
    public static var test: Self {
        let kept = MemoryUnread()
        return Self(
            unread: { await kept.unread },
            offset: { await kept.offset },
            keep: { await kept.keep($0, at: $1) }
        )
    }
}

/// What's unread in Turgai's database: a row for each person's conversation with something unread,
/// and how far it's read. Each change is one write, and keeping it again changes nothing, so the
/// offset is kept after it.
private struct UnreadMemoryTables: Sendable {
    // Held, not only its connection: the connection stays open while the tables are used.
    private let persistence: TurgaiPersistence
    private var connection: SQLiteConnection { persistence.connection }
    /// What it's known by among the read sides kept from the journal.
    private static let projection = "memory-unread"

    init(in persistence: TurgaiPersistence) async throws {
        self.persistence = persistence
        for statement in [
            """
            CREATE TABLE IF NOT EXISTS memory_unread (
                person          TEXT NOT NULL,
                conversation    TEXT NOT NULL,
                latest          TEXT NOT NULL,
                channel_message TEXT,
                heard_by        TEXT NOT NULL,
                said_at         REAL NOT NULL,
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

    func unread() async throws -> [UnreadConversation] {
        try await connection.query(
            "SELECT person, conversation, latest, channel_message, heard_by, said_at FROM memory_unread"
        ).map { row in
            guard let person = row.column("person")?.string.flatMap({ try? UserID(key: $0) }),
                let conversation = row.column("conversation")?.string.flatMap(ConversationID.init(stableKey:)),
                let latest = row.column("latest")?.string.flatMap(UUID.init(uuidString:)),
                let heardBy = row.column("heard_by")?.string,
                let saidAt = row.column("said_at")?.double
            else { throw UnreadMemoryError.invalidEntry }
            return UnreadConversation(
                person: person, conversation: conversation, latest: MemorySourceID(rawValue: latest),
                channelMessageID: row.column("channel_message")?.string.map(ChannelMessageID.init(rawValue:)),
                heardBy: AgentProfileID(heardBy), saidAt: Date(timeIntervalSince1970: saidAt))
        }
    }

    func offset() async throws -> Offset {
        let row = try await connection.query(
            "SELECT read_up_to FROM projection_offsets WHERE projection = ?", [.text(Self.projection)]
        ).first
        return Offset(Int64(row?.column("read_up_to")?.integer ?? 0))
    }

    func keep(_ change: UnreadMemoryChange?, at offset: Offset) async throws {
        switch change {
        case .said(let unread)?:
            _ = try await connection.query(
                """
                INSERT INTO memory_unread (person, conversation, latest, channel_message, heard_by, said_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (person, conversation) DO UPDATE SET latest = excluded.latest,
                    channel_message = excluded.channel_message, heard_by = excluded.heard_by,
                    said_at = excluded.said_at
                """,
                [
                    .text(unread.person.key), .text(unread.conversation.stableKey),
                    .text(unread.latest.rawValue.uuidString),
                    unread.channelMessageID.map { .text($0.rawValue) } ?? .null,
                    .text(unread.heardBy.rawValue), .float(unread.saidAt.timeIntervalSince1970),
                ])
        case .read(let person, let conversation, let through)?:
            _ = try await connection.query(
                "DELETE FROM memory_unread WHERE person = ? AND conversation = ? AND latest = ?",
                [.text(person.key), .text(conversation.stableKey), .text(through.rawValue.uuidString)])
        case .forgotten(let person)?:
            _ = try await connection.query("DELETE FROM memory_unread WHERE person = ?", [.text(person.key)])
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

/// What's unread, as ``UnreadMemoryStorage/test`` keeps it.
private actor MemoryUnread {
    private var rows: [Key: UnreadConversation] = [:]
    private(set) var offset = Offset.start

    private struct Key: Hashable {
        let person: UserID
        let conversation: ConversationID
    }

    var unread: [UnreadConversation] { Array(rows.values) }

    func keep(_ change: UnreadMemoryChange?, at offset: Offset) {
        switch change {
        case .said(let unread)?:
            rows[Key(person: unread.person, conversation: unread.conversation)] = unread
        case .read(let person, let conversation, let through)?:
            let key = Key(person: person, conversation: conversation)
            if rows[key]?.latest == through { rows[key] = nil }
        case .forgotten(let person)?:
            rows = rows.filter { $0.key.person != person }
        case nil:
            break
        }
        self.offset = offset
    }
}

/// Reads what people said into their memory, one conversation at a time, once they've been quiet
/// in it: from what's unread, kept from their memory events, so a restart picks up what was
/// waiting. One in the cluster, run where the journal can be read, as its projection must be.
public distributed actor MemoryPasses: ClusterSingleton {
    public typealias ActorSystem = ClusterSystem

    /// What the cluster knows it by.
    public static let singletonName = "turgai-memory-passes"
    /// Long enough for a follow-up exchange to be read with the one before.
    static let quietPeriod: Duration = .seconds(240)
    /// How long a failed pass waits before it's tried again, each time.
    private static let retries: [Duration] = [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(80)]

    private let storage: UnreadMemoryStorage
    /// The journal the memory events are read from: the concrete store, on this node.
    private let journal: any EventStore
    /// The agents' profiles, which name the models that read.
    private let agentProfiles: TurgaiAgentProfileStore
    private let endpoints: AgentModelEndpointFactory
    /// The projection, while it's the cluster's.
    private var following: Task<Void, Never>?
    /// The pass waiting or running for each person's conversation.
    private var passes: [UnreadKey: Task<Void, Never>] = [:]

    private struct UnreadKey: Hashable {
        let person: UserID
        let conversation: ConversationID
    }

    public init(
        actorSystem: ClusterSystem,
        storage: UnreadMemoryStorage,
        journal: any EventStore,
        agentProfiles: TurgaiAgentProfileStore,
        endpoints: AgentModelEndpointFactory
    ) {
        self.actorSystem = actorSystem
        self.storage = storage
        self.journal = journal
        self.agentProfiles = agentProfiles
        self.endpoints = endpoints
    }

    /// Reads what was unread when it started, each once its quiet is over, then follows the memory
    /// events while it's the cluster's: a new exchange starts its conversation's wait over.
    public func activateSingleton() async {
        do {
            for unread in try await storage.unread() { schedule(unread) }
        } catch {
            actorSystem.log.error(
                "What's unread for memory couldn't be read", metadata: ["error": .string(String(describing: error))])
        }
        let storage = storage
        let projection = Projection<UserEvent>(
            tag: .memory, offset: { try await storage.offset() },
            process: { envelope in
                guard let person = User.userID(persistenceID: envelope.persistenceID) else {
                    throw UnreadMemoryError.notAPerson(envelope.persistenceID)
                }
                let change = UnreadMemoryChange(envelope.event, of: person)
                try await storage.keep(change, envelope.offset)
                await self.whenLocal { $0.follow(change) }
            })
        let journal = journal
        let log = actorSystem.log
        following = Task {
            await projection.runRestarting(on: journal) { error in
                log.error(
                    "Memory passes failed to follow the memory events; they start again shortly",
                    metadata: ["error": .string(String(describing: error))])
            }
        }
    }

    public func passivateSingleton() async {
        following?.cancel()
        following = nil
        for pass in passes.values { pass.cancel() }
        passes = [:]
    }

    /// What `change`, now kept, starts or stops.
    private func follow(_ change: UnreadMemoryChange?) {
        switch change {
        case .said(let unread)?:
            schedule(unread)
        case .forgotten(let person)?:
            for key in passes.keys where key.person == person { passes.removeValue(forKey: key)?.cancel() }
        case .read?, nil:
            break
        }
    }

    /// `unread`'s pass, instead of one waiting for an earlier exchange there.
    private func schedule(_ unread: UnreadConversation) {
        let key = UnreadKey(person: unread.person, conversation: unread.conversation)
        passes[key]?.cancel()
        passes[key] = Task { await self.whenLocal { await $0.read(unread) } }
    }

    /// Reads `unread` once it's due, with the model of the agent that heard it, tried again after
    /// each failure; marks its latest message noted when something was.
    private func read(_ unread: UnreadConversation) async {
        let actorSystem = actorSystem
        let agentProfiles = agentProfiles
        let endpoints = endpoints
        let noted = await MemoryPass.run(
            after: .seconds(max(unread.due(after: Self.quietPeriod).timeIntervalSinceNow, 0)), retries: Self.retries,
            extract: {
                guard let model = try await agentProfiles.agentModelSnapshot(forProfileID: unread.heardBy.rawValue)
                else { throw MemoryPassError.noModel(unread.heardBy) }
                return try await MemoryExtractionService.extractAndCommit(
                    endpoint: try await model.endpoint(from: endpoints), actorSystem: actorSystem,
                    user: try await User.resolve(on: actorSystem, userID: unread.person),
                    conversation: unread.conversation, expectedLatestSourceID: unread.latest)
            },
            failed: { error in
                actorSystem.log.warning(
                    "Memory extraction failed", metadata: ["error": .string(String(describing: error))])
            }
        )
        guard noted else { return }
        try? await Conversation.resolve(on: actorSystem, conversationID: unread.conversation).noted(
            NotedMessage(id: MessageID(rawValue: unread.latest.rawValue), channelID: unread.channelMessageID))
    }
}

enum MemoryPassError: Error, Equatable {
    /// The agent that heard it has no profile to read it with.
    case noModel(AgentProfileID)
}
