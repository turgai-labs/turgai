import SQLiteNIO
import TurgaiDomain
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum TurgaiGroupError: Error, Equatable, Sendable {
    /// The kept id isn't a group's.
    case invalidGroup
}

extension GroupID {
    /// Turgai's own group: the accounts that sign in to it, its administrators as its admins. Its
    /// id is minted the first time it's asked for, and kept in Turgai's database from then on.
    public static func turgai(in persistence: TurgaiPersistence) async throws -> GroupID {
        let connection = persistence.connection
        _ = try await connection.query(
            """
            CREATE TABLE IF NOT EXISTS turgai_group (
                one INTEGER NOT NULL PRIMARY KEY CHECK (one = 1),
                id  TEXT    NOT NULL
            ) WITHOUT ROWID
            """)
        _ = try await connection.query(
            "INSERT INTO turgai_group (one, id) VALUES (1, ?) ON CONFLICT DO NOTHING", [.text(UUID().uuidString)])
        guard
            let id = try await connection.query("SELECT id FROM turgai_group WHERE one = 1").first?
                .column("id")?.string.flatMap(UUID.init(uuidString:))
        else { throw TurgaiGroupError.invalidGroup }
        return GroupID(rawValue: id)
    }
}
