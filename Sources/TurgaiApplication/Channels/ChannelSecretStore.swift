import NIOCore
import SQLiteNIO
import TurgaiDomain
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Stores credentials for channel transports. Credentials are deliberately
/// independent from the channel catalog and from the Channel actor state.
public actor ChannelSecretStore {
    private let storage: ChannelTokenStorage

    public init(storage: ChannelTokenStorage) {
        self.storage = storage
    }

    public func setToken(for channelID: UUID, token: String) async throws {
        let trimmed = token.trimmed()
        guard !trimmed.isEmpty else {
            throw TurgaiChannelError.invalidToken
        }
        try await storage.set(trimmed, channelID)
    }

    public func token(for channelID: UUID) async throws -> String? {
        try await storage.token(channelID)
    }

    public func hasToken(for channelID: UUID) async throws -> Bool {
        try await storage.token(channelID) != nil
    }

    public func remove(for channelID: UUID) async throws {
        try await storage.remove(channelID)
    }
}

public enum ChannelTokenStorageError: Error, Equatable, Sendable {
    /// A kept token that isn't one.
    case invalidToken
}

/// Where each channel's token is kept: one per channel, sealed.
public struct ChannelTokenStorage: Sendable {
    /// Keeps the token for the channel `id`, in place of the one it had.
    public var set: @Sendable (_ token: String, _ id: UUID) async throws -> Void
    /// The channel `id`'s token, when it has one.
    public var token: @Sendable (_ id: UUID) async throws -> String?
    /// Removes the channel `id`'s token.
    public var remove: @Sendable (_ id: UUID) async throws -> Void

    public init(
        set: @escaping @Sendable (_ token: String, _ id: UUID) async throws -> Void,
        token: @escaping @Sendable (_ id: UUID) async throws -> String?,
        remove: @escaping @Sendable (_ id: UUID) async throws -> Void
    ) {
        self.set = set
        self.token = token
        self.remove = remove
    }

    /// The tokens in Turgai's database, each sealed with `key` for its channel, their table made
    /// if it isn't there yet.
    public static func live(in persistence: TurgaiPersistence, key: SecretKey) async throws -> Self {
        let table = try await ChannelTokenTable(in: persistence, key: key)
        return Self(
            set: { try await table.set($0, for: $1) },
            token: { try await table.token(for: $0) },
            remove: { try await table.remove($0) }
        )
    }

    /// Forgets every token in Turgai's database, as starting over with a new key does.
    public static func forgetAll(in persistence: TurgaiPersistence) async throws {
        _ = try await persistence.connection.query("DROP TABLE IF EXISTS channel_tokens")
    }

    /// Tokens kept in memory, a new place each time.
    public static var test: Self {
        let tokens = MemoryChannelTokens()
        return Self(
            set: { await tokens.set($0, for: $1) },
            token: { await tokens.token(for: $0) },
            remove: { await tokens.remove($0) }
        )
    }
}

/// The tokens in Turgai's database, a table of their own.
private struct ChannelTokenTable: Sendable {
    // Held, not only its connection: the connection stays open while the table is used.
    private let persistence: TurgaiPersistence
    private let key: SecretKey
    private var connection: SQLiteConnection { persistence.connection }

    /// The table in `persistence`, made if it isn't there yet.
    init(in persistence: TurgaiPersistence, key: SecretKey) async throws {
        self.persistence = persistence
        self.key = key
        _ = try await connection.query(
            """
            CREATE TABLE IF NOT EXISTS channel_tokens (
                channel_id TEXT NOT NULL PRIMARY KEY,
                sealed     BLOB NOT NULL
            ) WITHOUT ROWID
            """)
    }

    private static func place(of id: UUID) -> SecretPlace {
        SecretPlace("channel_tokens", id.uuidString)
    }

    func set(_ token: String, for id: UUID) async throws {
        _ = try await connection.query(
            """
            INSERT INTO channel_tokens (channel_id, sealed) VALUES (?, ?)
            ON CONFLICT (channel_id) DO UPDATE SET sealed = excluded.sealed
            """,
            [.text(id.uuidString), .blob(ByteBuffer(bytes: try key.seal(token, for: Self.place(of: id))))])
    }

    func token(for id: UUID) async throws -> String? {
        guard
            let row = try await connection.query(
                "SELECT sealed FROM channel_tokens WHERE channel_id = ?", [.text(id.uuidString)]
            ).first
        else { return nil }
        guard let sealed = row.column("sealed")?.blob else { throw ChannelTokenStorageError.invalidToken }
        return try key.open(Data(sealed.readableBytesView), for: Self.place(of: id))
    }

    func remove(_ id: UUID) async throws {
        _ = try await connection.query("DELETE FROM channel_tokens WHERE channel_id = ?", [.text(id.uuidString)])
    }
}

/// The tokens of ``ChannelTokenStorage/test``.
private actor MemoryChannelTokens {
    private var tokens: [UUID: String] = [:]

    func set(_ token: String, for id: UUID) {
        tokens[id] = token
    }

    func token(for id: UUID) -> String? {
        tokens[id]
    }

    func remove(_ id: UUID) {
        tokens[id] = nil
    }
}
