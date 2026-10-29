import SystemPackage
import TurgaiDomain
#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Turgai's only file-mechanics boundary.
///
/// The client owns one root directory and knows how to read, write, append,
/// list, and delete files beneath it — atomically, with private permissions
/// (directories 0700, files 0600) — and nothing else. Every consumer (event
/// store, snapshot store, configuration stores) owns the layout and formats
/// of its own subtree; no file access bypasses this type.
public final class FileClient: Sendable {
    /// The root every path is resolved against. Created (0700) on init;
    /// everything below it is created lazily on first write.
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    public func exists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: path).path)
    }

    public func read(at path: String) throws -> Data? {
        let url = url(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Atomic whole-file write.
    public func write(_ data: Data, at path: String) throws {
        let url = url(for: path)
        try createParent(of: url)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    /// Creates the file or appends to it. Callers serializing per path (an
    /// actor, a single writer) get append-only semantics for free.
    public func append(_ data: Data, at path: String) throws {
        let url = url(for: path)
        try createParent(of: url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try data.write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return
        }
        let file = try FileDescriptor.open(FilePath(url.path), .writeOnly, options: [.append])
        defer { try? file.close() }
        _ = try file.writeAll(data)
    }

    public func delete(at path: String) throws {
        let url = url(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Sorted file names directly inside `path`. A missing directory lists as
    /// empty.
    public func entries(in path: String, withExtension ext: String? = nil) throws -> [String] {
        let url = url(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return
            urls
            .filter { url in ext.map { url.pathExtension == $0 } ?? true }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// Lazily pulled lines of a file, or nil when it does not exist.
    public func lines(at path: String) throws -> FileLines? {
        let url = url(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return FileLines(url: url)
    }

    private func url(for path: String) -> URL {
        directory.appendingPathComponent(path)
    }

    private func createParent(of url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

extension FileClient {
    /// A Codable document, nil when absent. Pretty-printed, key-sorted JSON is
    /// the project convention: configuration files stay human-editable.
    public func loadDocument<Value: Decodable>(at path: String) throws -> Value? {
        guard let data = try read(at: path) else { return nil }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    public func saveDocument<Value: Encodable>(_ document: Value, at path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(document), at: path)
    }

    /// A raw secret payload (token files, passwords), trimmed of surrounding
    /// whitespace. Secrets share the document mechanics; the name exists so
    /// call sites mark the intent.
    public func loadSecret(at path: String) throws -> String? {
        guard let data = try read(at: path) else { return nil }
        let value = String(decoding: data, as: UTF8.self)
            .trimmed()
        return value.isEmpty ? nil : value
    }

    public func saveSecret(_ secret: String, at path: String) throws {
        try write(Data(secret.utf8), at: path)
    }
}

/// The lines of a file, pulled a chunk at a time with plain reads of its descriptor.
///
/// Not `FileHandle.bytes`: its reads in a process share one reader, so a read that waits,
/// on a pipe that has nothing to say yet, holds up every other, and replaying a journal
/// would wait on it.
public struct FileLines: AsyncSequence, Sendable {
    public typealias Element = String

    let url: URL

    public func makeAsyncIterator() -> Iterator {
        Iterator(url: url)
    }

    public final class Iterator: AsyncIteratorProtocol {
        private let url: URL
        private var file: FileDescriptor?
        private var buffer = Data()
        private var ended = false

        /// How much of the file one read takes.
        private static let chunk = 64 * 1024

        init(url: URL) {
            self.url = url
        }

        deinit {
            try? file?.close()
        }

        public func next() async throws -> String? {
            while true {
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    return line
                }
                if ended {
                    guard !buffer.isEmpty else { return nil }
                    defer { buffer = Data() }
                    return String(decoding: buffer, as: UTF8.self)
                }
                let opened = try file ?? FileDescriptor.open(FilePath(url.path), .readOnly)
                file = opened
                var chunk = [UInt8](repeating: 0, count: Self.chunk)
                let count = try chunk.withUnsafeMutableBytes { try opened.read(into: $0) }
                if count == 0 {
                    ended = true
                    try opened.close()
                    file = nil
                } else {
                    buffer.append(contentsOf: chunk[..<count])
                }
            }
        }
    }
}
