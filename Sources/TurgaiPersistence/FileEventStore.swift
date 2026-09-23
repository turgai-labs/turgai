import EventSourcing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// File-backed event store used by the cluster journal plugin.
///
/// The store owns the journal layout — `journal/<escaped-id>.jsonl`, one JSON
/// envelope per line — on top of a FileClient, which only provides the file
/// mechanics.
public actor FileEventStore: EventStore {
    private struct DuplicateSequenceNumber: Error {}

    private let client: FileClient

    public init(client: FileClient) {
        self.client = client
    }

    public func persistEvent<Event: Codable & Sendable>(
        _ event: Event,
        id: String,
        sequenceNumber: Int64
    ) async throws {
        let path = journalPath(for: id)
        var line = try JSONEncoder().encode(
            EventEnvelope(
                persistenceID: id,
                sequenceNumber: sequenceNumber,
                event: event
            )
        )
        line.append(UInt8(ascii: "\n"))

        if let existing = try client.read(at: path) {
            let decoder = JSONDecoder()
            for existingLine in existing.split(
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
        }

        try client.append(line, at: path)
    }

    public func eventStream<Event: Codable & Sendable>(
        id: String,
        fromSequenceNumber: Int64
    ) async throws -> EventStream<Event> {
        guard let lines = try client.lines(at: journalPath(for: id)) else {
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }

        let decoder = JSONDecoder()
        return
            lines
            .map { line in
                try decoder.decode(
                    EventEnvelope<Event>.self,
                    from: Data(line.utf8)
                )
            }
            .filter { $0.sequenceNumber >= fromSequenceNumber }
    }

    private func journalPath(for id: String) -> String {
        let safe =
            id
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return "journal/\(safe).jsonl"
    }
}
