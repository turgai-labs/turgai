import AnyLanguageModel
import Foundation
import Hail
import SQLiteNIO
import TurgaiPersistence

extension AgentProviderConfiguration {
    /// The provider account `model`'s requests count against, which a request limit is set for:
    /// `nil` for a model that runs on this machine without HTTP.
    public func account(for model: AgentModel) -> ModelAccount? {
        switch self {
        case .ollama(let baseURL, _):
            // A cloud model is the account's, whichever server passes its requests on.
            let name = model.id.rawValue
            if name.hasSuffix(":cloud") || name.hasSuffix("-cloud") { return ModelAccount(rawValue: "ollama-cloud") }
            return ModelAccount(rawValue: "ollama@\(baseURL.host() ?? baseURL.absoluteString)")
        case .openAI: return ModelAccount(rawValue: "openai")
        case .anthropic: return ModelAccount(rawValue: "anthropic")
        case .gemini: return ModelAccount(rawValue: "gemini")
        case .openAICompatible(let baseURL, _, _, _):
            return ModelAccount(rawValue: baseURL.host() ?? baseURL.absoluteString)
        case .appleSystem: return nil
        #if Llama
            case .llamaCPP: return nil
        #endif
        }
    }
}

/// How many requests each provider account takes at once, as the dashboard sets them, and the
/// transports models send their requests with, which follow them as they change. The limits are
/// kept in their storage and read from it; the transports hold them live.
public actor RequestLimitStore {
    /// What a new installation starts with: Ollama's cloud takes one request at a time on its
    /// free plan.
    public static let defaultLimits: [ModelAccount: Int] = [ModelAccount(rawValue: "ollama-cloud"): 1]

    private let storage: RequestLimitStorage
    /// The transports models send their requests with.
    public nonisolated let transports: ModelTransports

    /// The limits kept in `storage`. The first time there are none, and the defaults are kept,
    /// so they're there whatever is set next.
    public init(storage: RequestLimitStorage) async throws {
        var limits = try await storage.all()
        if limits.isEmpty {
            for (account, limit) in Self.defaultLimits { try await storage.set(limit, account) }
            limits = try await storage.all()
        }
        self.storage = storage
        self.transports = ModelTransports(limits: limits.compactMapValues { $0 })
    }

    /// `account`'s limit; `nil` when its requests aren't limited.
    public func limit(for account: ModelAccount) async throws -> Int? {
        try await storage.limit(account)
    }

    /// Sets `account`'s limit, at least one; `nil` lifts it. Models use it from their next request.
    public func setLimit(_ limit: Int?, for account: ModelAccount) async throws {
        let limit = limit.map { max(1, $0) }
        try await storage.set(limit, account)
        await transports.setLimit(limit, for: account)
    }
}

public enum RequestLimitStorageError: Error, Equatable, Sendable {
    /// A kept limit that isn't one.
    case invalidLimit
}

/// Where the request limits are kept: one per provider account, a lifted limit kept as lifted.
public struct RequestLimitStorage: Sendable {
    /// Each account's limit as it was set, `nil` where it was lifted.
    public var all: @Sendable () async throws -> [ModelAccount: Int?]
    /// The account's limit; `nil` when it was lifted or never set.
    public var limit: @Sendable (ModelAccount) async throws -> Int?
    /// Sets the account's limit, at least one; `nil` lifts it.
    public var set: @Sendable (Int?, ModelAccount) async throws -> Void

    public init(
        all: @escaping @Sendable () async throws -> [ModelAccount: Int?],
        limit: @escaping @Sendable (ModelAccount) async throws -> Int?,
        set: @escaping @Sendable (Int?, ModelAccount) async throws -> Void
    ) {
        self.all = all
        self.limit = limit
        self.set = set
    }

    /// The request limits in Turgai's database, their table made if it isn't there yet.
    public static func live(in persistence: TurgaiPersistence) async throws -> Self {
        let table = try await RequestLimitTable(in: persistence)
        return Self(
            all: { try await table.all() },
            limit: { try await table.limit(for: $0) },
            set: { try await table.set($0, for: $1) }
        )
    }

    /// Request limits kept in memory, a new place each time.
    public static var test: Self {
        let limits = MemoryRequestLimits()
        return Self(
            all: { await limits.all() },
            limit: { await limits.limit(for: $0) },
            set: { await limits.set($0, for: $1) }
        )
    }
}

/// The request limits in Turgai's database, a table of their own.
private struct RequestLimitTable: Sendable {
    // Held, not only its connection: the connection stays open while the table is used.
    private let persistence: TurgaiPersistence
    private var connection: SQLiteConnection { persistence.connection }

    /// The table in `persistence`, made if it isn't there yet.
    init(in persistence: TurgaiPersistence) async throws {
        self.persistence = persistence
        _ = try await connection.query(
            """
            CREATE TABLE IF NOT EXISTS request_limits (
                account      TEXT    NOT NULL PRIMARY KEY,
                max_requests INTEGER CHECK (max_requests >= 1)
            ) WITHOUT ROWID
            """)
    }

    func all() async throws -> [ModelAccount: Int?] {
        var limits: [ModelAccount: Int?] = [:]
        for row in try await connection.query("SELECT account, max_requests FROM request_limits") {
            guard let account = row.column("account")?.string else { throw RequestLimitStorageError.invalidLimit }
            limits[ModelAccount(rawValue: account)] = row.column("max_requests")?.integer.map { Int($0) }
        }
        return limits
    }

    func limit(for account: ModelAccount) async throws -> Int? {
        try await connection.query("SELECT max_requests FROM request_limits WHERE account = ?", [.text(account.rawValue)])
            .first?.column("max_requests")?.integer.map { Int($0) }
    }

    func set(_ limit: Int?, for account: ModelAccount) async throws {
        _ = try await connection.query(
            """
            INSERT INTO request_limits (account, max_requests) VALUES (?, ?)
            ON CONFLICT (account) DO UPDATE SET max_requests = excluded.max_requests
            """,
            [.text(account.rawValue), limit.map { .integer(SQLiteInt64($0)) } ?? .null])
    }
}

/// The limits of ``RequestLimitStorage/test``.
private actor MemoryRequestLimits {
    private var limits: [ModelAccount: Int?] = [:]

    func all() -> [ModelAccount: Int?] {
        limits
    }

    func limit(for account: ModelAccount) -> Int? {
        limits[account] ?? nil
    }

    func set(_ limit: Int?, for account: ModelAccount) {
        limits[account] = .some(limit)
    }
}
