import Testing
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct FileClientTests {
    private struct Document: Codable, Equatable, Sendable {
        var name: String
        var count: Int
    }

    @Test
    func documentsRoundTripWithPrivatePermissions() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try FileClient(directory: directory)

        #expect(try client.loadDocument(at: "docs/missing.json") as Document? == nil)

        try client.saveDocument(Document(name: "one", count: 1), at: "docs/state.json")
        #expect(try client.loadDocument(at: "docs/state.json") == Document(name: "one", count: 1))

        let fileURL = directory.appendingPathComponent("docs/state.json")
        let permissions =
            try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        let parentPermissions =
            try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent("docs").path
            )[.posixPermissions] as? Int
        #expect(parentPermissions == 0o700)
    }

    @Test
    func secretsAreStoredRawAndLoadedTrimmed() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try FileClient(directory: directory)

        #expect(try client.loadSecret(at: "secrets/token") == nil)

        try client.saveSecret("  abc:123\n", at: "secrets/token")
        #expect(try client.loadSecret(at: "secrets/token") == "abc:123")

        try client.delete(at: "secrets/token")
        #expect(try client.loadSecret(at: "secrets/token") == nil)
        // Deleting twice is a no-op.
        try client.delete(at: "secrets/token")
    }

    @Test
    func appendCreatesThenAppends() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try FileClient(directory: directory)

        try client.append(Data("one\n".utf8), at: "logs/log.txt")
        try client.append(Data("two\n".utf8), at: "logs/log.txt")

        #expect(String(decoding: try #require(try client.read(at: "logs/log.txt")), as: UTF8.self) == "one\ntwo\n")

        var lines: [String] = []
        for try await line in try #require(try client.lines(at: "logs/log.txt")) {
            lines.append(line)
        }
        #expect(lines == ["one", "two"])
        #expect(try client.lines(at: "logs/missing.txt") == nil)
    }

    @Test
    func entriesListsSortedAndFiltersByExtension() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try FileClient(directory: directory)

        #expect(try client.entries(in: "missing") == [])

        try client.write(Data("b".utf8), at: "dir/b.jsonl")
        try client.write(Data("a".utf8), at: "dir/a.jsonl")
        try client.write(Data("c".utf8), at: "dir/c.txt")

        #expect(try client.entries(in: "dir") == ["a.jsonl", "b.jsonl", "c.txt"])
        #expect(try client.entries(in: "dir", withExtension: "jsonl") == ["a.jsonl", "b.jsonl"])
    }

    private func makeDirectory() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("turgai-file-client-\(UUID().uuidString)", isDirectory: true)
    }
}
