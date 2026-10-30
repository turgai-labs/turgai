import NIOCore
import SQLiteNIO

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Turgai's database: one SQLite file in its directory, opened once and shared by everything that
/// keeps something there. Each keeps its own tables and its own queries, in its own place: this
/// only opens the file and sets the connection up.
public final class TurgaiPersistence: Sendable {
    /// The file it's kept in, in Turgai's directory.
    public static let databaseName = "turgai.sqlite"

    /// How long a write waits for another connection's, in milliseconds.
    private static let busyTimeout = 5_000

    /// The one connection everything shares.
    public let connection: SQLiteConnection

    private init(connection: SQLiteConnection) {
        self.connection = connection
    }

    deinit {
        // Closed when it wasn't, as SQLiteNIO requires of a connection: one opened by a server
        // that never ran.
        guard !connection.isClosed else { return }
        connection.close().whenComplete { _ in }
    }

    /// Closes the database, once nothing uses it any more: its write-ahead log is checkpointed
    /// into the file and removed.
    public func close() async throws {
        try await connection.close()
    }

    /// The database in `directory`, a private one: its write-ahead log lets readers go on while
    /// one writes, a full sync keeps an acknowledged write through a power cut, references are
    /// enforced, and a second writer waits rather than fails.
    public static func open(in directory: URL) async throws -> TurgaiPersistence {
        let files = try FileClient(directory: directory)
        let path = files.directory.appendingPathComponent(Self.databaseName).path
        // Held first, so it's closed whichever pragma fails.
        let persistence = TurgaiPersistence(connection: try await SQLiteConnection.open(storage: .file(path: path)))
        for pragma in [
            "PRAGMA journal_mode = WAL", "PRAGMA synchronous = FULL", "PRAGMA foreign_keys = ON",
            "PRAGMA busy_timeout = \(Self.busyTimeout)",
        ] {
            _ = try await persistence.connection.query(pragma)
        }
        return persistence
    }

    /// Checks `key` is the one its secrets are sealed with, before any is opened: the first key it's
    /// given is that one, until its secrets are forgotten.
    public func check(_ key: SecretKey) async throws {
        _ = try await connection.query(
            """
            CREATE TABLE IF NOT EXISTS secret_key_check (
                one    INTEGER NOT NULL PRIMARY KEY CHECK (one = 1),
                sealed BLOB    NOT NULL
            ) WITHOUT ROWID
            """)
        if let row = try await connection.query("SELECT sealed FROM secret_key_check WHERE one = 1").first {
            guard let sealed = row.column("sealed")?.blob,
                (try? key.open(Data(sealed.readableBytesView), for: Self.keyCheck)) == Self.keyCheckValue
            else { throw SecretKeyError.notTheDatabasesKey }
            return
        }
        _ = try await connection.query(
            "INSERT INTO secret_key_check (one, sealed) VALUES (1, ?)",
            [.blob(ByteBuffer(bytes: try key.seal(Self.keyCheckValue, for: Self.keyCheck)))])
    }

    /// Forgets the key its secrets are sealed with: the next key it's given becomes it. Each
    /// context forgets its own sealed secrets.
    public func forgetKey() async throws {
        _ = try await connection.query("DROP TABLE IF EXISTS secret_key_check")
    }

    private static let keyCheck = SecretPlace("secret_key_check", "1")
    private static let keyCheckValue = "turgai"
}
