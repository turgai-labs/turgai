import Hail
import TurgaiDomain

/// Who a profile's agent works for, as its Hail context says: a conversation, or a person who
/// asked it as an object. Read once, from the context, where a turn's tools are made.
public enum AgentContext: Equatable, Sendable {
    /// Replying in a conversation.
    case conversation(ConversationID)
    /// Asked as an object, on this person's behalf: its own history, no conversation to reply in.
    /// It ends with its role, the agent's name in the person's scope, as an object's id ends with
    /// its name.
    case asked(by: TurgaiDomain.UserID, as: Role)

    private static let askedPrefix = "asked-by/"

    public init?(_ id: AgentContextID) {
        if id.rawValue.hasPrefix(Self.askedPrefix) {
            let rest = id.rawValue.dropFirst(Self.askedPrefix.count)
            guard let slash = rest.lastIndex(of: "/") else { return nil }
            let person = rest[..<slash]
            let role = rest[rest.index(after: slash)...]
            guard !person.isEmpty, !role.isEmpty else { return nil }
            self = .asked(by: TurgaiDomain.UserID(rawValue: String(person)), as: Role(String(role)))
        } else if let conversation = ConversationID(stableKey: id.rawValue) {
            self = .conversation(conversation)
        } else {
            return nil
        }
    }

    public var contextID: AgentContextID {
        switch self {
        case .conversation(let conversation): AgentContextID(conversation.stableKey)
        case .asked(let person, let role): AgentContextID("\(Self.askedPrefix)\(person.rawValue)/\(role.rawValue)")
        }
    }

    /// The person it works for.
    public var person: TurgaiDomain.UserID? {
        switch self {
        case .conversation(let conversation): conversation.participantUserID
        case .asked(let person, _): person
        }
    }
}
