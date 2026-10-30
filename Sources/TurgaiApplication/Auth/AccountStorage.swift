import SQLiteNIO
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// An account as it's kept: who it is, and the hash its password is checked against.
public struct StoredAccount: Equatable, Sendable {
    public let id: UUID
    public let username: String
    public let passwordHash: String
    public let status: Account.Status
    public let role: Account.Role

    public init(id: UUID, username: String, passwordHash: String, status: Account.Status, role: Account.Role) {
        self.id = id
        self.username = username
        self.passwordHash = passwordHash
        self.status = status
        self.role = role
    }

    public var account: Account {
        Account(id: id, username: username, status: status, role: role)
    }
}

public enum AccountStorageError: Error, Equatable, Sendable {
    /// A kept account that isn't one.
    case invalidAccount
    /// Another account already has this username.
    case usernameTaken
}

/// Where the accounts are kept: found by query, and kept by the rules that hold across them, a
/// username taken once and an approved administrator always left, each change in one write.
public struct AccountStorage: Sendable {
    /// Every account, by username.
    public var all: @Sendable () async throws -> [StoredAccount]
    public var named: @Sendable (_ username: String) async throws -> StoredAccount?
    public var withID: @Sendable (_ id: UUID) async throws -> StoredAccount?
    /// Whether an approved administrator exists.
    public var hasApprovedAdministrator: @Sendable () async throws -> Bool
    /// Keeps a new account: refused with ``AccountStorageError/usernameTaken`` when its username
    /// is taken.
    public var insert: @Sendable (StoredAccount) async throws -> Void
    /// Keeps the account unless an approved administrator exists already: whether it was kept.
    public var insertFirstAdministrator: @Sendable (StoredAccount) async throws -> Bool
    /// Sets the account `id`'s status unless that leaves no approved administrator: whether it
    /// was set.
    public var setStatus: @Sendable (Account.Status, _ id: UUID) async throws -> Bool
    /// Gives the account `id` the role unless that leaves no approved administrator: whether it
    /// was given.
    public var setRole: @Sendable (Account.Role, _ id: UUID) async throws -> Bool

    public init(
        all: @escaping @Sendable () async throws -> [StoredAccount],
        named: @escaping @Sendable (_ username: String) async throws -> StoredAccount?,
        withID: @escaping @Sendable (_ id: UUID) async throws -> StoredAccount?,
        hasApprovedAdministrator: @escaping @Sendable () async throws -> Bool,
        insert: @escaping @Sendable (StoredAccount) async throws -> Void,
        insertFirstAdministrator: @escaping @Sendable (StoredAccount) async throws -> Bool,
        setStatus: @escaping @Sendable (Account.Status, _ id: UUID) async throws -> Bool,
        setRole: @escaping @Sendable (Account.Role, _ id: UUID) async throws -> Bool
    ) {
        self.all = all
        self.named = named
        self.withID = withID
        self.hasApprovedAdministrator = hasApprovedAdministrator
        self.insert = insert
        self.insertFirstAdministrator = insertFirstAdministrator
        self.setStatus = setStatus
        self.setRole = setRole
    }

    /// The accounts in Turgai's database, their table made if it isn't there yet.
    public static func live(in persistence: TurgaiPersistence) async throws -> Self {
        let table = try await AccountTable(in: persistence)
        return Self(
            all: { try await table.all() },
            named: { try await table.account(named: $0) },
            withID: { try await table.account(id: $0) },
            hasApprovedAdministrator: { try await table.hasApprovedAdministrator() },
            insert: { try await table.insert($0) },
            insertFirstAdministrator: { try await table.insertFirstAdministrator($0) },
            setStatus: { try await table.setStatus($0, ofAccount: $1) },
            setRole: { try await table.setRole($0, ofAccount: $1) }
        )
    }

    /// Accounts kept in memory, a new place each time, by the same rules.
    public static var test: Self {
        let accounts = MemoryAccounts()
        return Self(
            all: { await accounts.all() },
            named: { await accounts.named($0) },
            withID: { await accounts.withID($0) },
            hasApprovedAdministrator: { await accounts.hasApprovedAdministrator() },
            insert: { try await accounts.insert($0) },
            insertFirstAdministrator: { try await accounts.insertFirstAdministrator($0) },
            setStatus: { status, id in
                await accounts.replace(id) {
                    StoredAccount(
                        id: id, username: $0.username, passwordHash: $0.passwordHash, status: status, role: $0.role)
                }
            },
            setRole: { role, id in
                await accounts.replace(id) {
                    StoredAccount(
                        id: id, username: $0.username, passwordHash: $0.passwordHash, status: $0.status, role: role)
                }
            }
        )
    }
}

/// The accounts in Turgai's database, a table of their own.
private struct AccountTable: Sendable {
    // Held, not only its connection: the connection stays open while the table is used.
    private let persistence: TurgaiPersistence
    private var connection: SQLiteConnection { persistence.connection }

    /// The table in `persistence`, made if it isn't there yet.
    init(in persistence: TurgaiPersistence) async throws {
        self.persistence = persistence
        _ = try await connection.query(
            """
            CREATE TABLE IF NOT EXISTS accounts (
                id            TEXT NOT NULL PRIMARY KEY,
                username      TEXT NOT NULL UNIQUE,
                password_hash TEXT NOT NULL,
                status        TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'disabled')),
                role          TEXT NOT NULL CHECK (role IN ('user', 'administrator', 'member')),
                created_at    TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            ) WITHOUT ROWID
            """)
    }

    private static let columns = "id, username, password_hash, status, role"

    func all() async throws -> [StoredAccount] {
        try await connection.query("SELECT \(Self.columns) FROM accounts ORDER BY username").map(Self.account(from:))
    }

    func account(named username: String) async throws -> StoredAccount? {
        try await connection.query("SELECT \(Self.columns) FROM accounts WHERE username = ?", [.text(username)])
            .first.map(Self.account(from:))
    }

    func account(id: UUID) async throws -> StoredAccount? {
        try await connection.query("SELECT \(Self.columns) FROM accounts WHERE id = ?", [.text(id.uuidString)])
            .first.map(Self.account(from:))
    }

    func hasApprovedAdministrator() async throws -> Bool {
        try await connection.query(
            "SELECT EXISTS (SELECT 1 FROM accounts WHERE role = 'administrator' AND status = 'approved') AS found"
        ).first?.column("found")?.integer == 1
    }

    func insert(_ account: StoredAccount) async throws {
        try await Self.refusingTakenUsernames {
            _ = try await connection.query(
                "INSERT INTO accounts (\(Self.columns)) VALUES (?, ?, ?, ?, ?)", Self.binds(of: account))
        }
    }

    func insertFirstAdministrator(_ account: StoredAccount) async throws -> Bool {
        try await Self.refusingTakenUsernames {
            try await !connection.query(
                """
                INSERT INTO accounts (\(Self.columns))
                SELECT ?, ?, ?, ?, ?
                WHERE NOT EXISTS (SELECT 1 FROM accounts WHERE role = 'administrator' AND status = 'approved')
                RETURNING id
                """,
                Self.binds(of: account)
            ).isEmpty
        }
    }

    func setStatus(_ status: Account.Status, ofAccount id: UUID) async throws -> Bool {
        try await !connection.query(
            """
            UPDATE accounts SET status = ?1
            WHERE id = ?2
              AND (?1 = 'approved' OR role != 'administrator' OR status != 'approved'
                   OR (SELECT COUNT(*) FROM accounts WHERE role = 'administrator' AND status = 'approved') > 1)
            RETURNING id
            """,
            [.text(status.rawValue), .text(id.uuidString)]
        ).isEmpty
    }

    func setRole(_ role: Account.Role, ofAccount id: UUID) async throws -> Bool {
        try await !connection.query(
            """
            UPDATE accounts SET role = ?1
            WHERE id = ?2
              AND (?1 = 'administrator' OR role != 'administrator' OR status != 'approved'
                   OR (SELECT COUNT(*) FROM accounts WHERE role = 'administrator' AND status = 'approved') > 1)
            RETURNING id
            """,
            [.text(role.rawValue), .text(id.uuidString)]
        ).isEmpty
    }

    private static func refusingTakenUsernames<Result>(_ write: () async throws -> Result) async throws -> Result {
        do {
            return try await write()
        } catch let error as SQLiteError where error.reason == .constraintUniqueFailed {
            throw AccountStorageError.usernameTaken
        }
    }

    private static func binds(of account: StoredAccount) -> [SQLiteData] {
        [
            .text(account.id.uuidString), .text(account.username), .text(account.passwordHash),
            .text(account.status.rawValue), .text(account.role.rawValue),
        ]
    }

    private static func account(from row: SQLiteRow) throws -> StoredAccount {
        guard let id = row.column("id")?.string.flatMap(UUID.init(uuidString:)),
            let username = row.column("username")?.string,
            let passwordHash = row.column("password_hash")?.string,
            let status = row.column("status")?.string.flatMap(Account.Status.init(rawValue:)),
            let role = row.column("role")?.string.flatMap(Account.Role.init(rawValue:))
        else { throw AccountStorageError.invalidAccount }
        return StoredAccount(id: id, username: username, passwordHash: passwordHash, status: status, role: role)
    }
}

/// The accounts of ``AccountStorage/test``.
private actor MemoryAccounts {
    private var accounts: [UUID: StoredAccount] = [:]

    func all() -> [StoredAccount] {
        accounts.values.sorted { $0.username < $1.username }
    }

    func named(_ username: String) -> StoredAccount? {
        accounts.values.first { $0.username == username }
    }

    func withID(_ id: UUID) -> StoredAccount? {
        accounts[id]
    }

    func hasApprovedAdministrator() -> Bool {
        approvedAdministrators > 0
    }

    func insert(_ account: StoredAccount) throws {
        guard named(account.username) == nil else { throw AccountStorageError.usernameTaken }
        accounts[account.id] = account
    }

    func insertFirstAdministrator(_ account: StoredAccount) throws -> Bool {
        guard !hasApprovedAdministrator() else { return false }
        try insert(account)
        return true
    }

    /// Replaces the account `id` with what `change` makes of it, unless that leaves no approved
    /// administrator: whether it was replaced.
    func replace(_ id: UUID, with change: (StoredAccount) -> StoredAccount) -> Bool {
        guard let previous = accounts[id] else { return false }
        accounts[id] = change(previous)
        guard approvedAdministrators > 0 else {
            accounts[id] = previous
            return false
        }
        return true
    }

    private var approvedAdministrators: Int {
        accounts.values.count { $0.role == .administrator && $0.status == .approved }
    }
}
