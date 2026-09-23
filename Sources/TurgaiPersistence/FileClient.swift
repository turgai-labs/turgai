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
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(data)
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
            .map(\.lastPathComponent)
            .filter { name in
                guard let ext else { return true }
                return (name as NSString).pathExtension == ext
            }
            .sorted()
    }

    /// Lazily pulled lines of a file, or nil when it does not exist.
    public func lines(at path: String) throws -> AsyncLineSequence<FileHandle.AsyncBytes>? {
        let url = url(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try FileHandle(forReadingFrom: url).bytes.lines
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
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public func saveSecret(_ secret: String, at path: String) throws {
        try write(Data(secret.utf8), at: path)
    }
}
