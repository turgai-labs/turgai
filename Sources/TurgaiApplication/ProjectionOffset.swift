import EventSourcing
import SQLiteNIO
import TurgaiPersistence

/// How far a projection has read the journal, by its name: kept in Turgai's database, or in memory.
public struct ProjectionOffset: Sendable {
    /// Where it's read up to.
    public var read: @Sendable () async throws -> Offset
    /// That it's read up to an offset.
    public var keep: @Sendable (Offset) async throws -> Void

    public init(
        read: @escaping @Sendable () async throws -> Offset, keep: @escaping @Sendable (Offset) async throws -> Void
    ) {
        self.read = read
        self.keep = keep
    }

    /// The offset of the projection `name`, in Turgai's database, its table made if it isn't there.
    public static func live(named name: String, in persistence: TurgaiPersistence) async throws -> Self {
        let table = try await OffsetTable(in: persistence)
        return Self(read: { try await table.offset(of: name) }, keep: { try await table.keep($0, of: name) })
    }

    /// An offset kept in memory, a new one each time.
    public static var test: Self {
        let kept = KeptOffset()
        return Self(read: { await kept.offset }, keep: { await kept.keep($0) })
    }
}

/// The projections' offsets in Turgai's database.
private struct OffsetTable: Sendable {
    // Held, not only its connection: the connection stays open while the table is used.
    private let persistence: TurgaiPersistence
    private var connection: SQLiteConnection { persistence.connection }

    init(in persistence: TurgaiPersistence) async throws {
        self.persistence = persistence
        _ = try await connection.query(
            """
            CREATE TABLE IF NOT EXISTS projection_offsets (
                projection TEXT    NOT NULL PRIMARY KEY,
                read_up_to INTEGER NOT NULL
            ) WITHOUT ROWID
            """)
    }

    func offset(of projection: String) async throws -> Offset {
        let row = try await connection.query(
            "SELECT read_up_to FROM projection_offsets WHERE projection = ?", [.text(projection)]
        ).first
        return Offset(Int64(row?.column("read_up_to")?.integer ?? 0))
    }

    func keep(_ offset: Offset, of projection: String) async throws {
        _ = try await connection.query(
            """
            INSERT INTO projection_offsets (projection, read_up_to) VALUES (?, ?)
            ON CONFLICT (projection) DO UPDATE SET read_up_to = excluded.read_up_to
            """,
            [.text(projection), .integer(Int(offset.rawValue))])
    }
}

/// An offset of ``ProjectionOffset/test``.
private actor KeptOffset {
    private(set) var offset = Offset.start

    func keep(_ offset: Offset) {
        self.offset = offset
    }
}
