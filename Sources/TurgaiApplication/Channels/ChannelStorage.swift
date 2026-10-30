import SQLiteNIO
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum ChannelStorageError: Error, Equatable, Sendable {
    /// A kept channel that isn't one.
    case invalidChannel
}

/// Where the channels there are kept, each with its provider's id: from when it's made until it's
/// deleted.
public struct ChannelStorage: Sendable {
    /// Keeps the channel `id` of the provider, unless it's there already.
    public var add: @Sendable (_ id: UUID, _ providerID: String) async throws -> Void
    /// Removes the channel `id`.
    public var remove: @Sendable (_ id: UUID) async throws -> Void
    /// Every channel of the provider, in the order they were made.
    public var ids: @Sendable (_ providerID: String) async throws -> [UUID]

    public init(
        add: @escaping @Sendable (_ id: UUID, _ providerID: String) async throws -> Void,
        remove: @escaping @Sendable (_ id: UUID) async throws -> Void,
        ids: @escaping @Sendable (_ providerID: String) async throws -> [UUID]
    ) {
        self.add = add
        self.remove = remove
        self.ids = ids
    }

    /// The channels in Turgai's database, their table made if it isn't there yet.
    public static func live(in persistence: TurgaiPersistence) async throws -> Self {
        let table = try await ChannelTable(in: persistence)
        return Self(
            add: { try await table.add($0, providerID: $1) },
            remove: { try await table.remove($0) },
            ids: { try await table.ids(providerID: $0) }
        )
    }

    /// Channels kept in memory, a new place each time.
    public static var test: Self {
        let channels = MemoryChannels()
        return Self(
            add: { await channels.add($0, providerID: $1) },
            remove: { await channels.remove($0) },
            ids: { await channels.ids(providerID: $0) }
        )
    }
}

/// The channels in Turgai's database, a table of their own.
private struct ChannelTable: Sendable {
    // Held, not only its connection: the connection stays open while the table is used.
    private let persistence: TurgaiPersistence
    private var connection: SQLiteConnection { persistence.connection }

    /// The table in `persistence`, made if it isn't there yet.
    init(in persistence: TurgaiPersistence) async throws {
        self.persistence = persistence
        _ = try await connection.query(
            """
            CREATE TABLE IF NOT EXISTS channels (
                id         TEXT NOT NULL PRIMARY KEY,
                provider   TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
            ) WITHOUT ROWID
            """)
    }

    func add(_ id: UUID, providerID: String) async throws {
        _ = try await connection.query(
            "INSERT INTO channels (id, provider) VALUES (?, ?) ON CONFLICT DO NOTHING",
            [.text(id.uuidString), .text(providerID)])
    }

    func remove(_ id: UUID) async throws {
        _ = try await connection.query("DELETE FROM channels WHERE id = ?", [.text(id.uuidString)])
    }

    func ids(providerID: String) async throws -> [UUID] {
        try await connection.query(
            "SELECT id FROM channels WHERE provider = ? ORDER BY created_at, id", [.text(providerID)]
        ).map { row in
            guard let id = row.column("id")?.string.flatMap(UUID.init(uuidString:)) else {
                throw ChannelStorageError.invalidChannel
            }
            return id
        }
    }
}

/// The channels of ``ChannelStorage/test``.
private actor MemoryChannels {
    private var channels: [(id: UUID, providerID: String)] = []

    func add(_ id: UUID, providerID: String) {
        guard !channels.contains(where: { $0.id == id }) else { return }
        channels.append((id, providerID))
    }

    func remove(_ id: UUID) {
        channels.removeAll { $0.id == id }
    }

    func ids(providerID: String) -> [UUID] {
        channels.filter { $0.providerID == providerID }.map(\.id)
    }
}
