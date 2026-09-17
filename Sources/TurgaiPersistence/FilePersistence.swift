import EventSourcing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A handle to Turgai's file-backed persistence.
///
/// The client owns the file layout and all file operations. Event and
/// snapshot stores are protocol adapters created only when the cluster
/// journal plugin is built.
public final class FilePersistenceClient: Sendable {
    private struct EventEnvelopeRecord: Decodable {
        let persistenceID: String
    }

    private struct SnapshotRecord: Codable, Sendable {
        let stateType: String
        let coveredSequenceNumber: Int64
        let payload: Data
    }

    private let journalDirectory: URL
    private let snapshotDirectory: URL

    public init(directory: URL) throws {
        self.journalDirectory = directory.appendingPathComponent(
            "journal",
            isDirectory: true
        )
        self.snapshotDirectory = directory.appendingPathComponent(
            "snapshots",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: snapshotDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Discovers journal IDs from their persisted envelopes. Filename
    /// escaping is intentionally not treated as reversible.
    public func persistenceIDs(withPrefix prefix: String = "") throws -> [String] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: journalDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let decoder = JSONDecoder()

        var ids: [String] = []
        for url in urls where url.pathExtension == "jsonl" {
            let data = try Data(contentsOf: url)
            guard
                let line = data.split(
                    separator: 0x0A,
                    omittingEmptySubsequences: true
                ).first
            else {
                continue
            }

            let record = try decoder.decode(
                EventEnvelopeRecord.self,
                from: Data(line)
            )
            if record.persistenceID.hasPrefix(prefix) {
                ids.append(record.persistenceID)
            }
        }

        return ids.sorted()
    }

    /// Reads a journal through the client without exposing an EventStore.
    public func events<Event: Codable & Sendable>(
        for persistenceID: String,
        fromSequenceNumber: Int64 = 1
    ) async throws -> [Event] {
        let stream: EventStream<Event> = try eventStream(
            id: persistenceID,
            fromSequenceNumber: fromSequenceNumber
        )
        var events: [Event] = []
        for try await envelope in stream {
            events.append(envelope.event)
        }
        return events
    }

    func persistEvent<Event: Codable & Sendable>(
        _ event: Event,
        id: String,
        sequenceNumber: Int64
    ) throws {
        let url = eventFileURL(for: id)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var line = try encoder.encode(
            EventEnvelope(
                persistenceID: id,
                sequenceNumber: sequenceNumber,
                event: event
            )
        )
        line.append(UInt8(ascii: "\n"))

        if !FileManager.default.fileExists(atPath: url.path) {
            try line.write(to: url, options: .withoutOverwriting)
            return
        }

        let existingData = try Data(contentsOf: url)
        for existingLine in existingData.split(
            separator: 0x0A,
            omittingEmptySubsequences: true
        ) {
            let stored = try decoder.decode(
                EventEnvelope<Event>.self,
                from: Data(existingLine)
            )
            if stored.sequenceNumber == sequenceNumber {
                throw DuplicateSequenceNumber()
            }
        }

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(line)
    }

    func eventStream<Event: Codable & Sendable>(
        id: String,
        fromSequenceNumber: Int64
    ) throws -> EventStream<Event> {
        let url = eventFileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AsyncThrowingStream<EventEnvelope<Event>, any Error> { continuation in
                continuation.finish()
            }
        }

        let decoder = JSONDecoder()
        return try FileHandle(forReadingFrom: url)
            .bytes
            .lines
            .map { line in
                try decoder.decode(
                    EventEnvelope<Event>.self,
                    from: Data(line.utf8)
                )
            }
            .filter { $0.sequenceNumber >= fromSequenceNumber }
    }

    func saveSnapshot<State: Codable & Sendable>(
        _ state: State,
        id: PersistenceID,
        coveredSequenceNumber: Int64
    ) throws {
        let url = snapshotFileURL(for: id)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let records = try readSnapshotRecords(at: url, decoder: decoder)
        let stateType = String(reflecting: State.self)
        let latestSequence =
            records
            .filter { $0.stateType == stateType }
            .map(\.coveredSequenceNumber)
            .max()

        guard latestSequence.map({ coveredSequenceNumber > $0 }) ?? true else {
            return
        }

        var updated = records
        updated.append(
            SnapshotRecord(
                stateType: stateType,
                coveredSequenceNumber: coveredSequenceNumber,
                payload: try encoder.encode(state)
            )
        )
        try writeSnapshotRecords(updated, to: url, encoder: encoder)
    }

    func deleteSnapshots(
        id: PersistenceID,
        matching criteria: SnapshotSelectionCriteria
    ) throws {
        let url = snapshotFileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let retained = try readSnapshotRecords(at: url, decoder: decoder).filter {
            !criteria.includes($0.coveredSequenceNumber)
        }
        try writeSnapshotRecords(retained, to: url, encoder: encoder)
    }

    func latestSnapshot<State: Codable & Sendable>(
        id: PersistenceID
    ) throws -> Snapshot<State>? {
        let url = snapshotFileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let decoder = JSONDecoder()
        let records = try readSnapshotRecords(at: url, decoder: decoder)
        let stateType = String(reflecting: State.self)
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

    private func readSnapshotRecords(
        at url: URL,
        decoder: JSONDecoder
    ) throws -> [SnapshotRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let data = try Data(contentsOf: url)
        return
            try data
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { try decoder.decode(SnapshotRecord.self, from: Data($0)) }
    }

    private func writeSnapshotRecords(
        _ records: [SnapshotRecord],
        to url: URL,
        encoder: JSONEncoder
    ) throws {
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }

    private func eventFileURL(for id: String) -> URL {
        journalDirectory.appendingPathComponent(fileName(for: id))
    }

    private func snapshotFileURL(for id: PersistenceID) -> URL {
        snapshotDirectory.appendingPathComponent(fileName(for: id))
    }

    private func fileName(for id: String) -> String {
        let safe =
            id
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return "\(safe).jsonl"
    }
}

private struct DuplicateSequenceNumber: Error {}
