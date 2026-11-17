import NIOCore
import SQLiteNIO
import TurgaiDomain
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public actor AgentCredentialStore {
    private let storage: AgentCredentialStorage

    public init(storage: AgentCredentialStorage) {
        self.storage = storage
    }

    public func save(_ value: String, for reference: AgentCredentialReference) async throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TurgaiAgentCredentialError.empty }
        try await storage.save(value, reference)
    }

    public func value(for reference: AgentCredentialReference) async throws -> String? {
        try await storage.value(reference)
    }

    public func contains(_ reference: AgentCredentialReference) async throws -> Bool {
        try await storage.value(reference) != nil
    }

    public func remove(_ reference: AgentCredentialReference) async throws {
        try await storage.remove(reference)
    }
}

public enum TurgaiAgentCredentialError: Error, Sendable, Equatable {
    case empty
    case missing(AgentCredentialReference)
    /// A kept credential that isn't one.
    case invalidCredential
}

/// Where the agents' credentials, a provider's API key each, are kept: sealed, by reference.
public struct AgentCredentialStorage: Sendable {
    /// Keeps the credential for the reference, in place of the one it had.
    public var save: @Sendable (_ value: String, _ reference: AgentCredentialReference) async throws -> Void
    /// The reference's credential, when there is one.
    public var value: @Sendable (_ reference: AgentCredentialReference) async throws -> String?
    /// Removes the reference's credential.
    public var remove: @Sendable (_ reference: AgentCredentialReference) async throws -> Void

    public init(
        save: @escaping @Sendable (_ value: String, _ reference: AgentCredentialReference) async throws -> Void,
        value: @escaping @Sendable (_ reference: AgentCredentialReference) async throws -> String?,
        remove: @escaping @Sendable (_ reference: AgentCredentialReference) async throws -> Void
    ) {
        self.save = save
        self.value = value
        self.remove = remove
    }

    /// The credentials in Turgai's database, each sealed with `key` for its reference, their table
    /// made if it isn't there yet.
    public static func live(in persistence: TurgaiPersistence, key: SecretKey) async throws -> Self {
        let table = try await AgentCredentialTable(in: persistence, key: key)
        return Self(
            save: { try await table.save($0, for: $1) },
            value: { try await table.value(for: $0) },
            remove: { try await table.remove($0) }
        )
    }

    /// Forgets every credential in Turgai's database, as starting over with a new key does.
    public static func forgetAll(in persistence: TurgaiPersistence) async throws {
        _ = try await persistence.connection.query("DROP TABLE IF EXISTS agent_credentials")
    }

    /// Credentials kept in memory, a new place each time.
    public static var test: Self {
        let credentials = MemoryAgentCredentials()
        return Self(
            save: { await credentials.save($0, for: $1) },
            value: { await credentials.value(for: $0) },
            remove: { await credentials.remove($0) }
        )
    }
}

/// The credentials in Turgai's database, a table of their own.
private struct AgentCredentialTable: Sendable {
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
            CREATE TABLE IF NOT EXISTS agent_credentials (
                reference TEXT NOT NULL PRIMARY KEY,
                sealed    BLOB NOT NULL
            ) WITHOUT ROWID
            """)
    }

    private static func place(of reference: AgentCredentialReference) -> SecretPlace {
        SecretPlace("agent_credentials", reference.rawValue)
    }

    func save(_ value: String, for reference: AgentCredentialReference) async throws {
        _ = try await connection.query(
            """
            INSERT INTO agent_credentials (reference, sealed) VALUES (?, ?)
            ON CONFLICT (reference) DO UPDATE SET sealed = excluded.sealed
            """,
            [.text(reference.rawValue), .blob(ByteBuffer(bytes: try key.seal(value, for: Self.place(of: reference))))])
    }

    func value(for reference: AgentCredentialReference) async throws -> String? {
        guard
            let row = try await connection.query(
                "SELECT sealed FROM agent_credentials WHERE reference = ?", [.text(reference.rawValue)]
            ).first
        else { return nil }
        guard let sealed = row.column("sealed")?.blob else { throw TurgaiAgentCredentialError.invalidCredential }
        return try key.open(Data(sealed.readableBytesView), for: Self.place(of: reference))
    }

    func remove(_ reference: AgentCredentialReference) async throws {
        _ = try await connection.query(
            "DELETE FROM agent_credentials WHERE reference = ?", [.text(reference.rawValue)])
    }
}

/// The credentials of ``AgentCredentialStorage/test``.
private actor MemoryAgentCredentials {
    private var credentials: [AgentCredentialReference: String] = [:]

    func save(_ value: String, for reference: AgentCredentialReference) {
        credentials[reference] = value
    }

    func value(for reference: AgentCredentialReference) -> String? {
        credentials[reference]
    }

    func remove(_ reference: AgentCredentialReference) {
        credentials[reference] = nil
    }
}
