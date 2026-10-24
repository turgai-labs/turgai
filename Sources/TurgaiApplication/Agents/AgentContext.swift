import Hail
import TurgaiDomain

/// What a profile's agent answers for, as its Hail context says: a conversation, or being asked as
/// an object. Read once, from the context, where a turn's tools are made.
public enum AgentContext: Equatable, Sendable {
    /// Replying in a conversation.
    case conversation(ConversationID)
    /// Asked as an object: its own history, no conversation to reply in. It ends with its role, the
    /// agent's name among the objects, as an object's id ends with its name.
    case asked(as: Role)

    private static let askedPrefix = "asked/"

    public init?(_ id: AgentContextID) {
        if id.rawValue.hasPrefix(Self.askedPrefix) {
            let role = id.rawValue.dropFirst(Self.askedPrefix.count)
            guard !role.isEmpty, !role.contains("/") else { return nil }
            self = .asked(as: Role(String(role)))
        } else if let conversation = ConversationID(stableKey: id.rawValue) {
            self = .conversation(conversation)
        } else {
            return nil
        }
    }

    public var contextID: AgentContextID {
        switch self {
        case .conversation(let conversation): AgentContextID(conversation.stableKey)
        case .asked(let role): AgentContextID(Self.askedPrefix + role.rawValue)
        }
    }

    /// The person it works for: a conversation's. One asked as an object works for no one person.
    public var person: TurgaiDomain.UserID? {
        switch self {
        case .conversation(let conversation): conversation.participantUserID
        case .asked: nil
        }
    }
}
