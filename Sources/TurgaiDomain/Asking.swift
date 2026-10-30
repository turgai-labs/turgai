#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Exactly what someone wants done, compared as a value: a thing whose access a space's admins
/// decide, as an object's own decide its. How it's sent, its headers and its credentials, isn't
/// part of it.
public enum ExactRequest: Hashable, Codable, Sendable, CustomStringConvertible {
    /// An HTTP request: its method, its URL, and what it sends, empty for nothing.
    case http(method: String, url: String, body: Data)
    /// A file read.
    case readFile(path: String)
    /// A directory listed.
    case listFiles(path: String)
    /// A file written, with what's written.
    case writeFile(path: String, content: String)
    /// A command run in a terminal, in a directory.
    case command(String, arguments: [String], in: String)
    /// A program run with its arguments, in a directory.
    case program(String, arguments: [String], in: String)

    /// As the people deciding read it: `GET https://example.com`.
    public var description: String {
        switch self {
        case .http(let method, let url, let body):
            "\(method) \(url)" + (body.isEmpty ? "" : "\n\(String(decoding: body, as: UTF8.self))")
        case .readFile(let path): "read \(path)"
        case .listFiles(let path): "list \(path)"
        case .writeFile(let path, let content): "write \(path)\n\(content)"
        case .command(let command, let arguments, let directory), .program(let command, let arguments, let directory):
            ([command] + arguments).joined(separator: " ") + " (in \(directory))"
        }
    }
}

extension ExactRequest {
    /// It, written down: what a refusal of it carries, so it's read back as exactly it. `nil` for
    /// one that can't be.
    public var encoded: Data? {
        try? JSONEncoder().encode(self)
    }

    /// The exact request `encoded` is, when it's one.
    public init?(encoded: Data) {
        guard let request = try? JSONDecoder().decode(Self.self, from: encoded) else { return nil }
        self = request
    }
}

/// Which access request it is: the same one however often it's asked for again while it waits.
public struct AccessRequestID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// Someone asking their space's admins to run exactly what they may not run yet, until they answer:
/// waiting, or allowed once and not yet run.
public struct AccessRequest: Hashable, Codable, Sendable, Identifiable {
    public let id: AccessRequestID
    public let request: ExactRequest
    /// Whose it is.
    public let by: UserID
    public let standing: Standing

    /// Where it stands.
    public enum Standing: Hashable, Codable, Sendable {
        /// Waiting for an admin's answer.
        case waiting
        /// Allowed once: the next scope that opens for whoever asked has it, and none after.
        case allowedOnce
    }

    public init(id: AccessRequestID, request: ExactRequest, by: UserID, standing: Standing) {
        self.id = id
        self.request = request
        self.by = by
        self.standing = standing
    }

    /// The same request, standing as `standing`.
    public func standing(_ standing: Standing) -> AccessRequest {
        AccessRequest(id: id, request: request, by: by, standing: standing)
    }
}

/// An admin's answer to an access request.
public enum AccessAnswer: Hashable, Codable, Sendable {
    /// The next scope that opens for whoever asked has it, and none after: what it allows doesn't
    /// change.
    case once
    /// It's shared with whoever asked: every scope that opens for them from now on has it.
    case always
    /// It's shared with everyone in the space: every scope that opens for any of them has it.
    case everyone
    case no

    /// The answer, said with exactly what it answers: what whoever asked is told.
    public func said(about request: ExactRequest) -> String {
        switch self {
        case .once: "Allowed once: \(request)"
        case .always: "Allowed from now on: \(request)"
        case .everyone: "Allowed for everyone here from now on: \(request)"
        case .no: "Not allowed: \(request)"
        }
    }
}
