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
    /// A kept row that isn't a space's member or name.
    case invalidEntry
}

/// What one of a space's events changes in the directory: what the space is called, whether it's in
/// use, or who's in it and with what role. Each leaves the directory as it is when it's kept a
/// second time.
public enum SpaceDirectoryChange: Hashable, Sendable {
    case named(SpaceID, SpaceName)
    case status(SpaceID, SpaceStatus)
    case member(SpaceID, UserID, SpaceRole)
    case left(SpaceID, UserID)

    /// What `event`, the space `space`'s, changes: none for what the directory doesn't show.
    public init?(_ event: SpaceEvent, in space: SpaceID) {
        switch event {
        case .named(let name): self = .named(space, name)
        case .joined(let person, let role), .roleChanged(let person, let role): self = .member(space, person, role)
        case .left(let person): self = .left(space, person)
        case .archived: self = .status(space, .archived)
        case .unarchived: self = .status(space, .active)
        case .asked, .answered, .spent, .invited, .inviteUsed, .inviteTakenBack: return nil
        }
    }
}

/// Where the space directory is kept: the named spaces each person is in, and how far into the
/// spaces' events it's read.
public struct SpaceDirectoryStorage: Sendable {
    /// The named spaces the person is in, with their role in each, the first joined first.
    public var spaces: @Sendable (UserID) async throws -> [SpaceListing]
    /// Where it's read the spaces' events up to.
    public var offset: @Sendable () async throws -> Offset
    /// Keeps a change, kept at an offset, then that it's read up to it.
    public var keep: @Sendable (SpaceDirectoryChange?, Offset) async throws -> Void

    public init(
        spaces: @escaping @Sendable (UserID) async throws -> [SpaceListing],
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
            offset: { try await tables.offset() },
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

/// The directory in Turgai's database: each named space's name, each person in a space with their
/// role and when they joined, and how far it's read. Each change is one write, and keeping it
/// again changes nothing, so the offset is kept after it.
private struct SpaceDirectoryTables: Sendable {
    // Held, not only its connection: the connection stays open while the tables are used.
    private let persistence: TurgaiPersistence
    private var connection: SQLiteConnection { persistence.connection }
    /// What it's known by among the read sides kept from the journal.
    private static let projection = "space-directory"

    init(in persistence: TurgaiPersistence) async throws {
        self.persistence = persistence
        for statement in [
            """
            CREATE TABLE IF NOT EXISTS space_names (
                space TEXT NOT NULL PRIMARY KEY,
                name  TEXT NOT NULL
            ) WITHOUT ROWID
            """,
            // A space that isn't in use: one with no row is.
            """
            CREATE TABLE IF NOT EXISTS space_status (
                space  TEXT NOT NULL PRIMARY KEY,
                status TEXT NOT NULL CHECK (status IN ('active', 'archived'))
            ) WITHOUT ROWID
            """,
            // A person's spaces, by when they joined: the offset of the event they joined in.
            """
            CREATE TABLE IF NOT EXISTS space_members (
                person    TEXT    NOT NULL,
                space     TEXT    NOT NULL,
                role      TEXT    NOT NULL CHECK (role IN ('member', 'admin')),
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

    func spaces(of person: UserID) async throws -> [SpaceListing] {
        try await connection.query(
            """
            SELECT space_members.space, name, role, COALESCE(status, 'active') AS status FROM space_members
            JOIN space_names ON space_names.space = space_members.space
            LEFT JOIN space_status ON space_status.space = space_members.space
            WHERE person = ? ORDER BY joined_at
            """,
            [.text(person.key)]
        ).map { row in
            guard let space = row.column("space")?.string.flatMap(UUID.init(uuidString:)),
                let name = row.column("name")?.string.flatMap(SpaceName.init),
                let role = row.column("role")?.string.flatMap(SpaceRole.init(rawValue:)),
                let status = row.column("status")?.string.flatMap(SpaceStatus.init(rawValue:))
            else { throw SpaceDirectoryError.invalidEntry }
            return SpaceListing(id: SpaceID(rawValue: space), name: name, role: role, status: status)
        }
    }

    func offset() async throws -> Offset {
        let row = try await connection.query(
            "SELECT read_up_to FROM projection_offsets WHERE projection = ?", [.text(Self.projection)]
        ).first
        return Offset(Int64(row?.column("read_up_to")?.integer ?? 0))
    }

    func keep(_ change: SpaceDirectoryChange?, at offset: Offset) async throws {
        switch change {
        case .named(let space, let name)?:
            _ = try await connection.query(
                """
                INSERT INTO space_names (space, name) VALUES (?, ?)
                ON CONFLICT (space) DO UPDATE SET name = excluded.name
                """,
                [.text(space.rawValue.uuidString), .text(name.rawValue)])
        case .status(let space, let status)?:
            _ = try await connection.query(
                """
                INSERT INTO space_status (space, status) VALUES (?, ?)
                ON CONFLICT (space) DO UPDATE SET status = excluded.status
                """,
                [.text(space.rawValue.uuidString), .text(status.rawValue)])
        case .member(let space, let person, let role)?:
            _ = try await connection.query(
                """
                INSERT INTO space_members (person, space, role, joined_at) VALUES (?, ?, ?, ?)
                ON CONFLICT (person, space) DO UPDATE SET role = excluded.role
                """,
                [
                    .text(person.key), .text(space.rawValue.uuidString), .text(role.rawValue),
                    .integer(Int(offset.rawValue)),
                ])
        case .left(let space, let person)?:
            _ = try await connection.query(
                "DELETE FROM space_members WHERE person = ? AND space = ?",
                [.text(person.key), .text(space.rawValue.uuidString)])
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

/// The directory of ``SpaceDirectoryStorage/test``.
private actor MemorySpaceDirectory {
    private var names: [SpaceID: SpaceName] = [:]
    private var statuses: [SpaceID: SpaceStatus] = [:]
    private var members: [UserID: [SpaceID: (role: SpaceRole, joinedAt: Offset)]] = [:]
    private(set) var offset = Offset.start

    func spaces(of person: UserID) -> [SpaceListing] {
        (members[person] ?? [:]).sorted { $0.value.joinedAt < $1.value.joinedAt }.compactMap { space, member in
            names[space].map {
                SpaceListing(id: space, name: $0, role: member.role, status: statuses[space] ?? .active)
            }
        }
    }

    func keep(_ change: SpaceDirectoryChange?, at offset: Offset) {
        switch change {
        case .named(let space, let name)?:
            names[space] = name
        case .status(let space, let status)?:
            statuses[space] = status
        case .member(let space, let person, let role)?:
            members[person, default: [:]][space] = (role, members[person]?[space]?.joinedAt ?? offset)
        case .left(let space, let person)?:
            members[person]?[space] = nil
        case nil:
            break
        }
        self.offset = offset
    }
}

/// The named spaces each person is in, kept from every space's events: one in the cluster, run
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

    /// The named spaces `person` is in, with their role in each, the first joined first.
    public distributed func spaces(of person: UserID) async throws -> [SpaceListing] {
        try await storage.spaces(person)
    }

    /// Follows the spaces' events while it's the cluster's directory: from where it read up to,
    /// and again from there whenever following them fails.
    public func activateSingleton() async {
        let storage = storage
        let projection = Projection<SpaceEvent>(tag: .space, offset: { try await storage.offset() }) { envelope in
            try await storage.keep(
                SpaceDirectoryChange(envelope.event, in: try Space.space(persistedAs: envelope.persistenceID)),
                envelope.offset)
        }
        let journal = journal
        let refreshInterval = refreshInterval
        let log = actorSystem.log
        following = Task {
            await projection.runRestarting(on: journal, refreshInterval: refreshInterval) { error in
                log.error(
                    "The space directory failed to follow the spaces' events; it starts again shortly",
                    metadata: ["error": .string(String(describing: error))])
            }
        }
    }

    public func passivateSingleton() async {
        following?.cancel()
        following = nil
    }
}
