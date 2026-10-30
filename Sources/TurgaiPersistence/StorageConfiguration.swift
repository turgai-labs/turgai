import EventSourcing
import NIOSSL
import PostgresEventStore
import PostgresNIO
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum TurgaiStorageConfigurationError: Error, Equatable, Sendable {
    case invalidPostgresURL
    case invalidPostgresUsername
    case invalidPostgresPassword
}

/// The persisted choice of where the journal is kept. Credentials are intentionally split: the
/// connection URL and username are configuration, while the password lives in a separate
/// mode-600 file managed by the dashboard.
public enum TurgaiStorageConfiguration: Codable, Equatable, Sendable {
    /// In Turgai's own database, in its directory.
    case local
    case postgres(url: URL, username: String)

    public static func postgresStore(url: URL, username: String) throws -> Self {
        guard Self.isValidPostgresURL(url) else {
            throw TurgaiStorageConfigurationError.invalidPostgresURL
        }
        let username = username.trimmed()
        guard !username.isEmpty else {
            throw TurgaiStorageConfigurationError.invalidPostgresUsername
        }
        return .postgres(url: url, username: username)
    }

    public var postgres: PostgresStorageConfiguration? {
        guard case .postgres(let url, let username) = self else { return nil }
        return PostgresStorageConfiguration(url: url, username: username)
    }

    private static func isValidPostgresURL(_ url: URL) -> Bool {
        let port = url.port ?? 5432
        guard
            let scheme = url.scheme?.lowercased(),
            scheme == "postgres" || scheme == "postgresql",
            let host = url.host,
            !host.isEmpty,
            (1...65_535).contains(port)
        else {
            return false
        }
        return !Self.databaseName(in: url).isEmpty
    }

    fileprivate static func databaseName(in url: URL) -> String {
        let path = url.path.trimmed(while: { $0 == "/" })
        return path.percentDecoded ?? path
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case url
        case username
    }

    private enum Kind: String, Codable {
        case local
        case postgres
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode(Kind.local, forKey: .kind)
        case .postgres(let url, let username):
            try container.encode(Kind.postgres, forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encode(username, forKey: .username)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .local:
            self = .local
        case .postgres:
            self = try Self.postgresStore(
                url: container.decode(URL.self, forKey: .url),
                username: container.decode(String.self, forKey: .username)
            )
        }
    }
}

public struct PostgresStorageConfiguration: Codable, Equatable, Sendable {
    public let url: URL
    public let username: String

    fileprivate init(url: URL, username: String) {
        self.url = url
        self.username = username
    }

    public var host: String {
        url.host ?? ""
    }

    public var port: Int {
        url.port ?? 5432
    }

    public var database: String {
        TurgaiStorageConfiguration.databaseName(in: url)
    }
}

/// Where the journal is kept, as the storage choice says: in Turgai's own database, or in
/// PostgreSQL, through a client of its own.
public enum JournalStorage: Sendable {
    case local
    case postgres(PostgresClient)

    public init(
        configuration: TurgaiStorageConfiguration,
        postgresPassword: String?
    ) throws {
        switch configuration {
        case .local:
            self = .local
        case .postgres(let url, let username):
            guard let postgresPassword, !postgresPassword.isEmpty else {
                throw TurgaiStorageConfigurationError.invalidPostgresPassword
            }
            let configuration = PostgresStorageConfiguration(url: url, username: username)
            self = .postgres(
                PostgresClient(
                    configuration: PostgresClient.Configuration(
                        host: configuration.host,
                        port: configuration.port,
                        username: configuration.username,
                        password: postgresPassword,
                        database: configuration.database,
                        tls: .prefer(.makeClientConfiguration())
                    )
                )
            )
        }
    }
}
