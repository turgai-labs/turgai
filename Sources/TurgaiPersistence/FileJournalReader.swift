#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Reads persisted actor identities from the file journal layout.
/// EventStore remains responsible for appending and replaying events; listing
/// IDs is a separate read-side query over the same files.
public struct FileJournalReader: Sendable {
    private let client: FileClient

    public init(client: FileClient) {
        self.client = client
    }

    public func persistenceIDs(withPrefix prefix: String = "") async throws -> [String] {
        let decoder = JSONDecoder()
        var ids: [String] = []
        for name in try client.entries(in: "journal", withExtension: "jsonl") {
            guard let lines = try client.lines(at: "journal/\(name)") else { continue }
            var iterator = lines.makeAsyncIterator()
            guard let firstLine = try await iterator.next(),
                let record = try? decoder.decode(
                    EnvelopeRecord.self,
                    from: Data(firstLine.utf8)
                ),
                record.persistenceID.hasPrefix(prefix)
            else {
                continue
            }

            ids.append(record.persistenceID)
        }
        return ids.sorted()
    }
}

private struct EnvelopeRecord: Decodable {
    let persistenceID: String
}
