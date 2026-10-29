import EventSourcing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// File-backed snapshot store used by the cluster journal plugin.
///
/// The store owns the snapshot layout — `snapshots/<escaped-id>.jsonl`, one
/// JSON record per line — on top of a FileClient, which only provides the
/// file mechanics.
public actor FileSnapshotStore: SnapshotStore {
    private struct SnapshotRecord: Codable, Sendable {
        let stateType: String
        let coveredSequenceNumber: Int64
        let payload: Data
    }

    private let client: FileClient

    public init(client: FileClient) {
        self.client = client
    }

    public func save<State: Codable & Sendable>(
        _ state: State,
        id: PersistenceID,
        coveredSequenceNumber: Int64
    ) async throws {
        let encoder = JSONEncoder()
        let records = try readRecords(at: snapshotPath(for: id))
        let stateType = String(reflecting: State.self)
        let latestSequence =
            records
            .filter { $0.stateType == stateType }
            .map(\.coveredSequenceNumber)
            .max()

        guard latestSequence.map({ coveredSequenceNumber > $0 }) ?? true else {
            return
        }

        try writeRecords(
            records + [
                SnapshotRecord(
                    stateType: stateType,
                    coveredSequenceNumber: coveredSequenceNumber,
                    payload: try encoder.encode(state)
                )
            ],
            to: snapshotPath(for: id)
        )
    }

    public func deleteSnapshots(
        id: PersistenceID,
        matching criteria: SnapshotSelectionCriteria
    ) async throws {
        let path = snapshotPath(for: id)
        let retained = try readRecords(at: path).filter {
            !criteria.includes($0.coveredSequenceNumber)
        }
        try writeRecords(retained, to: path)
    }

    public func latestSnapshot<State: Codable & Sendable>(
        id: PersistenceID
    ) async throws -> Snapshot<State>? {
        let records = try readRecords(at: snapshotPath(for: id))
        let stateType = String(reflecting: State.self)
        let decoder = JSONDecoder()
        guard
            let record =
                records
                .filter({ $0.stateType == stateType })
                .max(by: { $0.coveredSequenceNumber < $1.coveredSequenceNumber }),
            let state = try? decoder.decode(State.self, from: record.payload)
        else {
            return nil
        }

        return Snapshot(
            state: state,
            coveredSequenceNumber: record.coveredSequenceNumber
        )
    }

    private func readRecords(at path: String) throws -> [SnapshotRecord] {
        guard let data = try client.read(at: path) else { return [] }
        let decoder = JSONDecoder()
        return
            try data
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { try decoder.decode(SnapshotRecord.self, from: Data($0)) }
    }

    private func writeRecords(
        _ records: [SnapshotRecord],
        to path: String
    ) throws {
        let encoder = JSONEncoder()
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        try client.write(data, at: path)
    }

    private func snapshotPath(for id: PersistenceID) -> String {
        let safe =
            id
            .replacing("/", with: "_")
            .replacing(":", with: "_")
            .replacing("\\", with: "_")
        return "snapshots/\(safe).jsonl"
    }
}
