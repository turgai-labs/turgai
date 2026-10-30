import NIOCore
import SQLiteNIO
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum SessionSecretStorageError: Error, Equatable, Sendable {
    /// The kept secret isn't one.
    case invalidSecret
}

/// Where the secret that signs sessions is kept: one, made the first time it's asked for.
public struct SessionSecretStorage: Sendable {
    /// The secret's bytes.
    public var secret: @Sendable () async throws -> Data

    public init(secret: @escaping @Sendable () async throws -> Data) {
        self.secret = secret
    }

    /// The secret in Turgai's database, sealed with `key`, its table made if it isn't there yet.
    public static func live(in persistence: TurgaiPersistence, key: SecretKey) async throws -> Self {
        let table = try await SessionSecretTable(in: persistence, key: key)
        return Self(secret: { try await table.secret() })
    }

    /// Forgets the secret in Turgai's database, as starting over with a new key does: every
    /// session signed with it ends.
    public static func forgetAll(in persistence: TurgaiPersistence) async throws {
        _ = try await persistence.connection.query("DROP TABLE IF EXISTS session_secret")
    }

    /// A secret kept in memory, a new one each time.
    public static var test: Self {
        let secret = SecretKey.newBytes()
        return Self(secret: { secret })
    }
}

/// The secret in Turgai's database, a table of its own.
private struct SessionSecretTable: Sendable {
    // Held, not only its connection: the connection stays open while the table is used.
    private let persistence: TurgaiPersistence
    private let key: SecretKey
    private var connection: SQLiteConnection { persistence.connection }

    private static let place = SecretPlace("session_secret", "1")

    /// The table in `persistence`, made if it isn't there yet.
    init(in persistence: TurgaiPersistence, key: SecretKey) async throws {
        self.persistence = persistence
        self.key = key
        _ = try await connection.query(
            """
            CREATE TABLE IF NOT EXISTS session_secret (
                one    INTEGER NOT NULL PRIMARY KEY CHECK (one = 1),
                sealed BLOB    NOT NULL
            ) WITHOUT ROWID
            """)
    }

    /// The secret, made the first time.
    func secret() async throws -> Data {
        if let kept = try await kept() { return kept }
        let sealed = try key.seal(SecretKey.newBytes().base64EncodedString(), for: Self.place)
        _ = try await connection.query(
            "INSERT INTO session_secret (one, sealed) VALUES (1, ?) ON CONFLICT DO NOTHING",
            [.blob(ByteBuffer(bytes: sealed))])
        guard let kept = try await kept() else { throw SessionSecretStorageError.invalidSecret }
        return kept
    }

    private func kept() async throws -> Data? {
        guard let row = try await connection.query("SELECT sealed FROM session_secret WHERE one = 1").first else {
            return nil
        }
        guard let sealed = row.column("sealed")?.blob,
            let secret = Data(base64Encoded: try key.open(Data(sealed.readableBytesView), for: Self.place))
        else { throw SessionSecretStorageError.invalidSecret }
        return secret
    }
}
