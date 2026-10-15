import DiscoverableActors
import Distributed

/// Messages as a Swift type: an enumeration whose cases are the messages, each with its
/// arguments, made `@Describable`. Its schema is the spec, so a message's name and arguments are
/// written once, in its case, and sending one encodes the case.
///
/// ```swift
/// @Describable enum RefundManager: Messages { case refundRequested(number: Int, total: Double) }
/// ```
public protocol Messages: Codable, Describable, Sendable {}

extension Messages {
    /// The message as sent: its case's name, and its arguments by name, the way synthesized
    /// `Codable` writes a case, `{"refundRequested": {"number": 1, "total": 40}}`.
    func sent() throws(MessagesError) -> (name: String, arguments: JSONValue) {
        let encoded: JSONValue
        do { encoded = try JSONValue(encoding: self) } catch { throw .unencodable("\(self)", reason: "\(error)") }
        guard case .object(let tagged) = encoded, tagged.count == 1, let (name, arguments) = tagged.first else {
            throw .notACase("\(self)")
        }
        return (name, arguments)
    }
}

public enum MessagesError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    case notACase(String)
    case unencodable(String, reason: String)

    public var description: String {
        switch self {
        case .notACase(let value): "`\(value)` isn't a message: a message is one case of an enumeration."
        case .unencodable(let value, let reason): "`\(value)` can't be sent: \(reason)"
        }
    }
}

extension DiscoverableActor {
    /// Sends `message` to this object, as one of its actions.
    public nonisolated func send<M: Messages>(_ message: M) async throws {
        let (name, arguments) = try message.sent()
        try await invoke(name, arguments: arguments)
    }
}
