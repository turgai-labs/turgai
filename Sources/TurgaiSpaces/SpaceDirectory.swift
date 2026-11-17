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
    /// Every space's events, which the space directory is kept from.
    public static let space = EventTag("space")
}

public enum SpaceDirectoryError: Error, Equatable, Sendable {
    /// A journal that isn't a space's.
    case notASpace(PersistenceID)
    /// A kept row that isn't a space's member.
    case invalidEntry
}

/// What one of a space's events changes in the directory: who's in it, or how it's listed to them.
/// Each leaves the directory as it is when it's kept a second time.
public enum SpaceDirectoryChange: Hashable, Sendable {
    case joined(SpaceID, [UserID])
    case left(SpaceID, UserID)
    /// How it's listed changed: its name, whether it's archived, or what someone in it may do.
    case listed(SpaceID)

    /// What `event`, the space `space`'s, changes: none for what the directory doesn't show.
    public init?(_ event: SpaceEvent, in space: SpaceID) {
        switch event {
        case .made(_, let admins, _, _): self = .joined(space, admins.elements.sorted { $0.key < $1.key })
        case .joined(let person, _): self = .joined(space, [person])
        case .left(let person): self = .left(space, person)
        case .named, .archived, .unarchived, .placed, .adminMade, .adminSteppedDown, .permissionsSet, .groupRemoved:
            self = .listed(space)
        case .connectionAdded, .connectionChanged, .connectionRemoved, .groupMade, .botAdded, .botChanged,
            .botRemoved, .mainChosen, .asked, .answered, .spent, .invited, .inviteUsed, .inviteTakenBack:
            return nil
        }
    }
}

/// What a person following their spaces is told: they're in one more, they're no longer in one, or
/// one of theirs is listed differently. Each by its id: how it's listed to them, they ask it.
public enum SpaceNotice: Hashable, Codable, Sendable {
    case joined(SpaceID)
    case left(SpaceID)
    case listed(SpaceID)
}

/// Where the space directory is kept: the spaces each person is in, and how far into the spaces'
/// events it's read.
public struct SpaceDirectoryStorage: Sendable {
    /// The spaces the person is in, the first joined first.
    public var spaces: @Sendable (UserID) async throws -> [SpaceID]
    /// The people in the space.
    public var people: @Sendable (SpaceID) async throws -> [UserID]
    /// Where it's read the spaces' events up to.
    public var offset: @Sendable () async throws -> Offset
    /// Keeps a change, kept at an offset, then that it's read up to it.
    public var keep: @Sendable (SpaceDirectoryChange?, Offset) async throws -> Void

    public init(
        spaces: @escaping @Sendable (UserID) async throws -> [SpaceID],
        people: @escaping @Sendable (SpaceID) async throws -> [UserID],
        offset: @escaping @Sendable () async throws -> Offset,
        keep: @escaping @Sendable (SpaceDirectoryChange?, Offset) async throws -> Void
    ) {
        self.spaces = spaces
        self.people = people
        self.offset = offset
        self.keep = keep
    }

    /// The directory in Turgai's database, its tables made if they aren't there yet.
    public static func live(in persistence: TurgaiPersistence) async throws -> Self {
        let tables = try await SpaceDirectoryTables(in: persistence)
        return Self(
            spaces: { try await tables.spaces(of: $0) },
            people: { try await tables.people(in: $0) },
            offset: { try await tables.offset(of: SpaceDirectoryTables.projection) },
            keep: { try await tables.keep($0, at: $1) }
        )
    }

    /// A directory kept in memory, a new one each time.
    public static var test: Self {
        let directory = MemorySpaceDirectory()
        return Self(
            spaces: { await directory.spaces(of: $0) },
            people: { await directory.people(in: $0) },
            offset: { await directory.offset },
            keep: { await directory.keep($0, at: $1) }
        )
    }
}

/// The directory in Turgai's database: each person in a space with when they joined, and how far
/// it's read. Each change is one write, and keeping it again changes nothing, so the offset is kept
/// after it.
private struct SpaceDirectoryTables: Sendable {
    // Held, not only its connection: the connection stays open while the tables are used.
    private let persistence: TurgaiPersistence
    private var connection: SQLiteConnection { persistence.connection }
    /// What it's known by among the read sides kept from the journal.
    static let projection = "space-directory"

    init(in persistence: TurgaiPersistence) async throws {
        self.persistence = persistence
        for statement in [
            // A person's spaces, by when they joined: the offset of the event they joined in.
            """
            CREATE TABLE IF NOT EXISTS space_members (
                person    TEXT    NOT NULL,
                space     TEXT    NOT NULL,
                joined_at INTEGER NOT NULL,
                PRIMARY KEY (person, space)
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

    func spaces(of person: UserID) async throws -> [SpaceID] {
        try await connection.query(
            "SELECT space FROM space_members WHERE person = ? ORDER BY joined_at", [.text(person.key)]
        ).map { row in
            guard let space = row.column("space")?.string.flatMap(UUID.init(uuidString:)) else {
                throw SpaceDirectoryError.invalidEntry
            }
            return SpaceID(rawValue: space)
        }
    }

    func people(in space: SpaceID) async throws -> [UserID] {
        try await connection.query(
            "SELECT person FROM space_members WHERE space = ?", [.text(space.rawValue.uuidString)]
        ).map { row in
            guard let key = row.column("person")?.string, let person = try? UserID(key: key) else {
                throw SpaceDirectoryError.invalidEntry
            }
            return person
        }
    }

    /// Where `projection` has read up to.
    func offset(of projection: String) async throws -> Offset {
        let row = try await connection.query(
            "SELECT read_up_to FROM projection_offsets WHERE projection = ?", [.text(projection)]
        ).first
        return Offset(Int64(row?.column("read_up_to")?.integer ?? 0))
    }

    func keep(_ change: SpaceDirectoryChange?, at offset: Offset) async throws {
        switch change {
        case .joined(let space, let people)?:
            for person in people {
                _ = try await connection.query(
                    """
                    INSERT INTO space_members (person, space, joined_at) VALUES (?, ?, ?)
                    ON CONFLICT (person, space) DO NOTHING
                    """,
                    [.text(person.key), .text(space.rawValue.uuidString), .integer(Int(offset.rawValue))])
            }
        case .left(let space, let person)?:
            _ = try await connection.query(
                "DELETE FROM space_members WHERE person = ? AND space = ?",
                [.text(person.key), .text(space.rawValue.uuidString)])
        case .listed, nil:
            break
        }
        try await read(Self.projection, upTo: offset)
    }

    /// `projection` read up to `offset`.
    private func read(_ projection: String, upTo offset: Offset) async throws {
        _ = try await connection.query(
            """
            INSERT INTO projection_offsets (projection, read_up_to) VALUES (?, ?)
            ON CONFLICT (projection) DO UPDATE SET read_up_to = excluded.read_up_to
            """,
            [.text(projection), .integer(Int(offset.rawValue))])
    }
}

/// The directory of ``SpaceDirectoryStorage/test``.
private actor MemorySpaceDirectory {
    private var members: [UserID: [SpaceID: Offset]] = [:]
    private(set) var offset = Offset.start

    func spaces(of person: UserID) -> [SpaceID] {
        (members[person] ?? [:]).sorted { $0.value < $1.value }.map(\.key)
    }

    func people(in space: SpaceID) -> [UserID] {
        members.filter { $0.value[space] != nil }.map(\.key)
    }

    func keep(_ change: SpaceDirectoryChange?, at offset: Offset) {
        switch change {
        case .joined(let space, let people)?:
            for person in people { members[person, default: [:]][space] = members[person]?[space] ?? offset }
        case .left(let space, let person)?:
            members[person]?[space] = nil
        case .listed, nil:
            break
        }
        self.offset = offset
    }
}

/// The spaces each person is in, kept from every space's events: one in the cluster, run
/// where the journal can be read, as its projection must be.
public distributed actor SpaceDirectory: ClusterSingleton {
    public typealias ActorSystem = ClusterSystem

    /// What the cluster knows it by.
    public static let singletonName = "turgai-space-directory"

    private let storage: SpaceDirectoryStorage
    /// The journal the spaces' events are read from: the concrete store, on this node.
    private let journal: any EventStore
    private let refreshInterval: Duration
    /// The projection, while it's the cluster's directory.
    private var following: Task<Void, Never>?
    /// Who follows each person's spaces as they change: a subscriber each, and whose they follow.
    private var pulls = Pulls<SpaceNotice>()
    private var followers: [UUID: UserID] = [:]

    /// A directory kept in `storage`, from the spaces' events in `journal`, read again every
    /// `refreshInterval` once it's caught up.
    public init(
        actorSystem: ClusterSystem,
        storage: SpaceDirectoryStorage,
        journal: any EventStore,
        refreshInterval: Duration = .seconds(1)
    ) {
        self.actorSystem = actorSystem
        self.storage = storage
        self.journal = journal
        self.refreshInterval = refreshInterval
    }

    /// The spaces `person` is in, the first joined first.
    public distributed func spaces(of person: UserID) async throws -> [SpaceID] {
        try await storage.spaces(person)
    }

    /// `person`'s spaces as they change, from now on, `for await notice in subscription`.
    public nonisolated func subscription(for person: UserID) async throws -> Subscription<SpaceNotice> {
        let subscriber = UUID()
        try await subscribe(subscriber, to: person)
        return Subscription(subscriber, pull: { try await self.next(for: $0) }, leave: { try await self.leave($0) })
    }

    distributed func subscribe(_ subscriber: UUID, to person: UserID) {
        pulls.subscribe(subscriber)
        followers[subscriber] = person
    }

    /// `subscriber`'s next notice: from its backlog, or the next one told. `nil` once it's left.
    distributed func next(for subscriber: UUID) async -> SpaceNotice? {
        switch pulls.take(subscriber) {
        case .element(let notice): return notice
        case .ended: return nil
        case .empty: return await withCheckedContinuation { pulls.park(subscriber, $0) }
        }
    }

    distributed func leave(_ subscriber: UUID) {
        pulls.leave(subscriber)
        followers.removeValue(forKey: subscriber)
    }

    /// `change` kept, then the people it touches told about it.
    private func keep(_ change: SpaceDirectoryChange?, at offset: Offset) async throws {
        try await storage.keep(change, offset)
        guard !pulls.isEmpty, let change else { return }
        let notices: [(UserID, SpaceNotice)]
        switch change {
        case .joined(let space, let people): notices = people.map { ($0, .joined(space)) }
        case .left(let space, let person): notices = [(person, .left(space))]
        case .listed(let space): notices = try await storage.people(space).map { ($0, .listed(space)) }
        }
        for (person, notice) in notices {
            pulls.tell(notice) { followers[$0] == person }
        }
    }

    /// Follows the spaces' events while it's the cluster's directory: from where it read up to,
    /// and again from there whenever following them fails.
    public func activateSingleton() async {
        following = Task {
            await Projection<SpaceEvent>(tag: .space).runRestarting(
                on: journal, refreshInterval: refreshInterval,
                offset: { try await self.storage.offset() },
                process: { envelope in
                    try await self.keep(
                        SpaceDirectoryChange(envelope.event, in: try Space.space(persistedAs: envelope.persistenceID)),
                        at: envelope.offset)
                },
                failed: { error in
                    self.actorSystem.log.error(
                        "The space directory failed to follow the spaces' events; it starts again shortly",
                        metadata: ["error": .string(String(describing: error))])
                })
        }
    }

    public func passivateSingleton() async {
        following?.cancel()
        following = nil
    }
}
