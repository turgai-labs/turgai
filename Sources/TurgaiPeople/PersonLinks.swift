import SQLiteNIO
import TurgaiDomain
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum PersonLinkStorageError: Error, Equatable, Sendable {
    /// A kept link that isn't between two persons.
    case invalidLink
}

/// Where it's kept which persons are the same human: each link a pair, and the links chaining, so
/// everyone linked to one is linked to the rest.
public struct PersonLinkStorage: Sendable {
    /// Keeps that the two are the same human, unless it's kept already.
    public var link: @Sendable (UserID, UserID) async throws -> Void
    /// Removes the link between the two.
    public var unlink: @Sendable (UserID, UserID) async throws -> Void
    /// Everyone linked to the person, through any chain of links, them aside.
    public var linked: @Sendable (UserID) async throws -> [UserID]
    /// Those linked to the person directly, them aside.
    public var pairedWith: @Sendable (UserID) async throws -> [UserID]

    public init(
        link: @escaping @Sendable (UserID, UserID) async throws -> Void,
        unlink: @escaping @Sendable (UserID, UserID) async throws -> Void,
        linked: @escaping @Sendable (UserID) async throws -> [UserID],
        pairedWith: @escaping @Sendable (UserID) async throws -> [UserID]
    ) {
        self.link = link
        self.unlink = unlink
        self.linked = linked
        self.pairedWith = pairedWith
    }

    /// The links in Turgai's database, their table made if it isn't there yet.
    public static func live(in persistence: TurgaiPersistence) async throws -> Self {
        let table = try await PersonLinkTable(in: persistence)
        return Self(
            link: { try await table.link($0, $1) },
            unlink: { try await table.unlink($0, $1) },
            linked: { try await table.linked(to: $0) },
            pairedWith: { try await table.paired(with: $0) }
        )
    }

    /// Links kept in memory, a new place each time.
    public static var test: Self {
        let links = MemoryPersonLinks()
        return Self(
            link: { await links.link($0, $1) },
            unlink: { await links.unlink($0, $1) },
            linked: { await links.linked(to: $0) },
            pairedWith: { await links.paired(with: $0) }
        )
    }
}

/// The links in Turgai's database, a table of their own: each pair once, its two persons in order.
private struct PersonLinkTable: Sendable {
    // Held, not only its connection: the connection stays open while the table is used.
    private let persistence: TurgaiPersistence
    private var connection: SQLiteConnection { persistence.connection }

    /// The table in `persistence`, made if it isn't there yet.
    init(in persistence: TurgaiPersistence) async throws {
        self.persistence = persistence
        _ = try await connection.query(
            """
            CREATE TABLE IF NOT EXISTS person_links (
                first     TEXT NOT NULL,
                second    TEXT NOT NULL,
                linked_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
                PRIMARY KEY (first, second),
                CHECK (first < second)
            ) WITHOUT ROWID
            """)
    }

    /// The pair's two persons, in the order it's kept in.
    private static func pair(_ one: UserID, _ other: UserID) -> [SQLiteData] {
        [one.key, other.key].sorted().map(SQLiteData.text)
    }

    func link(_ one: UserID, _ other: UserID) async throws {
        _ = try await connection.query(
            "INSERT INTO person_links (first, second) VALUES (?, ?) ON CONFLICT DO NOTHING", Self.pair(one, other))
    }

    func unlink(_ one: UserID, _ other: UserID) async throws {
        _ = try await connection.query(
            "DELETE FROM person_links WHERE first = ? AND second = ?", Self.pair(one, other))
    }

    func linked(to person: UserID) async throws -> [UserID] {
        // Following each link from whoever's reached, until no one new is: `UNION` keeps each
        // person once, so a loop of links ends.
        try await Self.persons(
            connection.query(
                """
                WITH RECURSIVE human(person) AS (
                    SELECT ?1
                    UNION
                    SELECT CASE WHEN link.first = human.person THEN link.second ELSE link.first END
                    FROM person_links AS link
                    JOIN human ON link.first = human.person OR link.second = human.person
                )
                SELECT person FROM human WHERE person != ?1 ORDER BY person
                """,
                [.text(person.key)]))
    }

    func paired(with person: UserID) async throws -> [UserID] {
        try await Self.persons(
            connection.query(
                """
                SELECT CASE WHEN first = ?1 THEN second ELSE first END AS person
                FROM person_links WHERE first = ?1 OR second = ?1 ORDER BY person
                """,
                [.text(person.key)]))
    }

    private static func persons(_ rows: [SQLiteRow]) throws -> [UserID] {
        try rows.map { row in
            guard let key = row.column("person")?.string else { throw PersonLinkStorageError.invalidLink }
            return try UserID(key: key)
        }
    }
}

/// The links of ``PersonLinkStorage/test``.
private actor MemoryPersonLinks {
    private var pairs: Set<Set<UserID>> = []

    func link(_ one: UserID, _ other: UserID) {
        guard one != other else { return }
        pairs.insert([one, other])
    }

    func unlink(_ one: UserID, _ other: UserID) {
        pairs.remove([one, other])
    }

    func linked(to person: UserID) -> [UserID] {
        var reached: Set<UserID> = [person]
        var next = [person]
        while let one = next.popLast() {
            for pair in pairs where pair.contains(one) {
                for other in pair where reached.insert(other).inserted { next.append(other) }
            }
        }
        reached.remove(person)
        return reached.sorted { $0.key < $1.key }
    }

    func paired(with person: UserID) -> [UserID] {
        pairs.filter { $0.contains(person) }.flatMap { $0.subtracting([person]) }.sorted { $0.key < $1.key }
    }
}
