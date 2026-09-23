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
    case invalidFileURL
    case invalidPostgresURL
    case invalidPostgresUsername
    case invalidPostgresPassword
}

/// The persisted storage choice. Credentials are intentionally split: the
/// connection URL and username are configuration, while the password lives in
/// a separate mode-600 file managed by the dashboard.
public enum TurgaiStorageConfiguration: Codable, Equatable, Sendable {
    case file(directory: URL)
    case postgres(url: URL, username: String)

    public static func fileStore(directory: URL) throws -> Self {
        guard directory.isFileURL else {
            throw TurgaiStorageConfigurationError.invalidFileURL
        }
        return .file(directory: directory.standardizedFileURL)
    }

    public static func postgresStore(url: URL, username: String) throws -> Self {
        guard Self.isValidPostgresURL(url) else {
            throw TurgaiStorageConfigurationError.invalidPostgresURL
        }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw TurgaiStorageConfigurationError.invalidPostgresUsername
        }
        return .postgres(url: url, username: username)
    }

    public var fileDirectory: URL? {
        guard case .file(let directory) = self else { return nil }
        return directory
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
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.removingPercentEncoding ?? path
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case directory
        case url
        case username
    }

    private enum Kind: String, Codable {
        case file
        case postgres
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .file(let directory):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(directory, forKey: .directory)
        case .postgres(let url, let username):
            try container.encode(Kind.postgres, forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encode(username, forKey: .username)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .file:
            self = try Self.fileStore(
                directory: container.decode(URL.self, forKey: .directory)
            )
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

/// One persistence backend selected before the cluster starts.
///
/// Nothing here retains an event or snapshot store: stores are constructed at
/// the point of use — the composition root builds each one exactly once and
/// passes it to the cluster journal plugin's factory — so the plugin boundary
/// is the only place a store ever lives.
public struct TurgaiPersistence: Sendable {
    /// The driver behind the selected backend. Store construction branches on
    /// this, once, where the stores are used.
    public enum Backend: Sendable {
        case file(FileClient)
        case postgres(PostgresClient)
    }

    public let backend: Backend

    public init(
        configuration: TurgaiStorageConfiguration,
        postgresPassword: String?
    ) throws {
        switch configuration {
        case .file(let directory):
            backend = .file(try FileClient(directory: directory))
        case .postgres(let url, let username):
            guard let postgresPassword, !postgresPassword.isEmpty else {
                throw TurgaiStorageConfigurationError.invalidPostgresPassword
            }
            let configuration = PostgresStorageConfiguration(url: url, username: username)
            backend = .postgres(
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
