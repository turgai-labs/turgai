import SQLiteNIO
import TurgaiDomain
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum TurgaiSpaceError: Error, Equatable, Sendable {
    /// The kept id isn't a space's.
    case invalidSpace
}

extension SpaceID {
    /// Turgai's own space: the accounts that sign in to it, its administrators as its admins. Its
    /// id is minted the first time it's asked for, and kept in Turgai's database from then on.
    public static func turgai(in persistence: TurgaiPersistence) async throws -> SpaceID {
        let connection = persistence.connection
        _ = try await connection.query(
            """
            CREATE TABLE IF NOT EXISTS turgai_space (
                one INTEGER NOT NULL PRIMARY KEY CHECK (one = 1),
                id  TEXT    NOT NULL
            ) WITHOUT ROWID
            """)
        _ = try await connection.query(
            "INSERT INTO turgai_space (one, id) VALUES (1, ?) ON CONFLICT DO NOTHING", [.text(UUID().uuidString)])
        guard
            let id = try await connection.query("SELECT id FROM turgai_space WHERE one = 1").first?
                .column("id")?.string.flatMap(UUID.init(uuidString:))
        else { throw TurgaiSpaceError.invalidSpace }
        return SpaceID(rawValue: id)
    }
}
