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

public enum TurgaiStorageConfigurationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidPostgresURL
    case invalidPostgresUsername
    /// No password for PostgreSQL: neither `PGPASSWORD` nor a line of the password file.
    case noPostgresPassword
    /// The password file is readable by others than its owner, which PostgreSQL refuses too.
    case postgresPasswordFileNotPrivate

    public var description: String {
        switch self {
        case .invalidPostgresURL: "The PostgreSQL URL isn't postgres://host:port/database."
        case .invalidPostgresUsername: "The PostgreSQL username is empty."
        case .noPostgresPassword:
            "No PostgreSQL password: set PGPASSWORD, or add a line for this database to ~/.pgpass."
        case .postgresPasswordFileNotPrivate:
            "The PostgreSQL password file can be read by others: make it readable only by its owner (chmod 600)."
        }
    }
}

/// The persisted choice of where the journal is kept. The connection URL and username are
/// configuration; the password is PostgreSQL's own, from `PGPASSWORD` or its password file, as
/// PostgreSQL's own clients read them.
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

    /// Its password, as PostgreSQL's own clients find it: `PGPASSWORD`, or the first line of the
    /// password file (`PGPASSFILE`, or `~/.pgpass`) that matches its host, port, database and
    /// user, `*` matching any. A password file others than its owner can read is refused.
    func password(environment: [String: String]) throws -> String {
        if let password = environment["PGPASSWORD"], !password.isEmpty { return password }
        let file =
            environment["PGPASSFILE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pgpass")
        guard let lines = try? String(contentsOf: file, encoding: .utf8) else {
            throw TurgaiStorageConfigurationError.noPostgresPassword
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        guard let permissions, permissions & 0o077 == 0 else {
            throw TurgaiStorageConfigurationError.postgresPasswordFileNotPrivate
        }
        let wanted = [host, String(port), database, username]
        for line in lines.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = Self.fields(of: line)
            guard fields.count == 5 else { continue }
            if zip(fields.prefix(4), wanted).allSatisfy({ $0 == "*" || $0 == $1 }) { return fields[4] }
        }
        throw TurgaiStorageConfigurationError.noPostgresPassword
    }

    /// A password file line's fields, split at each `:`, with `\:` and `\\` read as `:` and `\`.
    private static func fields(of line: Substring) -> [String] {
        var fields = [""]
        var escaped = false
        for character in line {
            if escaped {
                fields[fields.count - 1].append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == ":" {
                fields.append("")
            } else {
                fields[fields.count - 1].append(character)
            }
        }
        return fields
    }
}

/// Where the journal is kept, as the storage choice says: in Turgai's own database, or in
/// PostgreSQL, through a client of its own.
public enum JournalStorage: Sendable {
    case local
    case postgres(PostgresClient)

    /// - Parameter environment: where PostgreSQL's password is found, as its own clients find it.
    public init(
        configuration: TurgaiStorageConfiguration,
        environment: [String: String]
    ) throws {
        switch configuration {
        case .local:
            self = .local
        case .postgres(let url, let username):
            let configuration = PostgresStorageConfiguration(url: url, username: username)
            let postgresPassword = try configuration.password(environment: environment)
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
