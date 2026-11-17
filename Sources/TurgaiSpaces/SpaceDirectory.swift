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

/// What one of a space's events changes in the directory: who's in it. Each leaves the directory as
/// it is when it's kept a second time.
public enum SpaceDirectoryChange: Hashable, Sendable {
    case joined(SpaceID, [UserID])
    case left(SpaceID, UserID)

    /// What `event`, the space `space`'s, changes: none for what the directory doesn't show.
    public init?(_ event: SpaceEvent, in space: SpaceID) {
        switch event {
        case .made(_, let admins, _, _): self = .joined(space, admins.elements.sorted { $0.key < $1.key })
        case .joined(let person, _): self = .joined(space, [person])
        case .left(let person): self = .left(space, person)
        case .named, .connectionAdded, .connectionChanged, .connectionRemoved, .placed, .adminMade, .adminSteppedDown,
            .groupMade, .permissionsSet, .groupRemoved, .botAdded,
            .botChanged, .botRemoved, .mainChosen, .asked,
            .answered, .spent, .invited, .inviteUsed, .inviteTakenBack, .archived, .unarchived:
            return nil
        }
    }
}

/// Where the space directory is kept: the spaces each person is in, and how far into the spaces'
/// events it's read.
public struct SpaceDirectoryStorage: Sendable {
    /// The spaces the person is in, the first joined first.
    public var spaces: @Sendable (UserID) async throws -> [SpaceID]
    /// Where it's read the spaces' events up to.
    public var offset: @Sendable () async throws -> Offset
    /// Keeps a change, kept at an offset, then that it's read up to it.
    public var keep: @Sendable (SpaceDirectoryChange?, Offset) async throws -> Void

    public init(
        spaces: @escaping @Sendable (UserID) async throws -> [SpaceID],
        offset: @escaping @Sendable () async throws -> Offset,
        keep: @escaping @Sendable (SpaceDirectoryChange?, Offset) async throws -> Void
    ) {
        self.spaces = spaces
        self.offset = offset
        self.keep = keep
    }

    /// The directory in Turgai's database, its tables made if they aren't there yet.
    public static func live(in persistence: TurgaiPersistence) async throws -> Self {
        let tables = try await SpaceDirectoryTables(in: persistence)
        return Self(
            spaces: { try await tables.spaces(of: $0) },
            offset: { try await tables.offset(of: SpaceDirectoryTables.projection) },
            keep: { try await tables.keep($0, at: $1) }
        )
    }

    /// A directory kept in memory, a new one each time.
    public static var test: Self {
        let directory = MemorySpaceDirectory()
        return Self(
            spaces: { await directory.spaces(of: $0) },
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
        case nil:
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

    func keep(_ change: SpaceDirectoryChange?, at offset: Offset) {
        switch change {
        case .joined(let space, let people)?:
            for person in people { members[person, default: [:]][space] = members[person]?[space] ?? offset }
        case .left(let space, let person)?:
            members[person]?[space] = nil
        case nil:
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

    /// Follows the spaces' events while it's the cluster's directory: from where it read up to,
    /// and again from there whenever following them fails.
    public func activateSingleton() async {
        following = Task {
            await Projection<SpaceEvent>(tag: .space).runRestarting(
                on: journal, refreshInterval: refreshInterval,
                offset: { try await self.storage.offset() },
                process: { envelope in
                    try await self.storage.keep(
                        SpaceDirectoryChange(envelope.event, in: try Space.space(persistedAs: envelope.persistenceID)),
                        envelope.offset)
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
