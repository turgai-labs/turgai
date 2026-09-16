import EventSourcing
import NIOSSL
import NorbyDomain
import PostgresEventStore
import PostgresNIO

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum NorbyStorageConfigurationError: Error, Equatable, Sendable {
    case invalidFileURL
    case invalidPostgresURL
    case invalidPostgresUsername
    case invalidPostgresPassword
}

/// The persisted storage choice. Credentials are intentionally split: the
/// connection URL and username are configuration, while the password lives in
/// a separate mode-600 file managed by the dashboard.
public enum NorbyStorageConfiguration: Codable, Equatable, Sendable {
    case file(directory: URL)
    case postgres(url: URL, username: String)

    public static func fileStore(directory: URL) throws -> Self {
        guard directory.isFileURL else {
            throw NorbyStorageConfigurationError.invalidFileURL
        }
        return .file(directory: directory.standardizedFileURL)
    }

    public static func postgresStore(url: URL, username: String) throws -> Self {
        guard Self.isValidPostgresURL(url) else {
            throw NorbyStorageConfigurationError.invalidPostgresURL
        }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw NorbyStorageConfigurationError.invalidPostgresUsername
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
        NorbyStorageConfiguration.databaseName(in: url)
    }
}

public struct PostgresPersistenceStack: Sendable {
    public let client: PostgresClient
    public let eventStore: PostgresEventStore
    public let snapshotStore: PostgresSnapshotStore

    public init(
        configuration: PostgresStorageConfiguration,
        password: String
    ) throws {
        guard !password.isEmpty else {
            throw NorbyStorageConfigurationError.invalidPostgresPassword
        }
        let clientConfiguration = PostgresClient.Configuration(
            host: configuration.host,
            port: configuration.port,
            username: configuration.username,
            password: password,
            database: configuration.database,
            tls: .prefer(.makeClientConfiguration())
        )
        let client = PostgresClient(configuration: clientConfiguration)
        self.client = client
        self.eventStore = PostgresEventStore(client: client)
        self.snapshotStore = PostgresSnapshotStore(client: client)
    }

    public func setupDatabase() async throws {
        try await eventStore.setupDatabase()
        try await snapshotStore.setupDatabase()
    }
}

/// One persistence runtime selected before the cluster starts. The concrete
/// stores stay behind the EventSourcing protocols at the application boundary.
public enum NorbyPersistenceRuntime: Sendable {
    case file(
        client: FilePersistenceClient,
        eventStore: FileEventStore,
        snapshotStore: FileSnapshotStore
    )
    case postgres(PostgresPersistenceStack)

    public init(
        configuration: NorbyStorageConfiguration,
        postgresPassword: String?
    ) throws {
        switch configuration {
        case .file(let directory):
            let client = try FilePersistenceClient(directory: directory)
            self = .file(
                client: client,
                eventStore: FileEventStore(client: client),
                snapshotStore: FileSnapshotStore(client: client)
            )
        case .postgres(let url, let username):
            guard let postgresPassword else {
                throw NorbyStorageConfigurationError.invalidPostgresPassword
            }
            let configuration = PostgresStorageConfiguration(url: url, username: username)
            self = .postgres(
                try PostgresPersistenceStack(
                    configuration: configuration,
                    password: postgresPassword
                )
            )
        }
    }

    public var eventStore: any EventStore {
        switch self {
        case .file(_, let eventStore, _): eventStore
        case .postgres(let stack): stack.eventStore
        }
    }

    public var snapshotStore: any SnapshotStore {
        switch self {
        case .file(_, _, let snapshotStore): snapshotStore
        case .postgres(let stack): stack.snapshotStore
        }
    }

    public var postgresClient: PostgresClient? {
        guard case .postgres(let stack) = self else { return nil }
        return stack.client
    }

    public func setupDatabase() async throws {
        if case .postgres(let stack) = self {
            try await stack.setupDatabase()
        }
    }

    public func conversationJournals() async throws -> [ConversationJournal] {
        switch self {
        case .file(let client, _, _):
            return try await ConversationJournalReader(client: client).conversationJournals()
        case .postgres(let stack):
            return try await PostgresConversationJournalReader(
                client: stack.client,
                eventStore: stack.eventStore
            ).conversationJournals()
        }
    }
}
