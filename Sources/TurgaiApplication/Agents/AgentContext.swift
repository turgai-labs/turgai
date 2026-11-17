import Hail
import TurgaiDomain
import TurgaiHail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What a bot's agent answers for, as its Hail context says: a conversation of its space, or being
/// asked as an object there. Read once, from the context, where a turn's tools are made.
public enum AgentContext: Equatable, Sendable {
    /// Replying in a conversation of a space.
    case conversation(ConversationID, in: SpaceID)
    /// Asked as an object in a space: its own history, no conversation to reply in. It ends with its
    /// role, the agent's name among the objects, as an object's id ends with its name.
    case asked(as: Role, in: SpaceID)
    /// Thinking for one run of a user's tool, `tool`, that the bot `caller` called in a space: with
    /// that bot's model, a history of its own for the run.
    case toolRun(String, calledBy: Role, in: SpaceID, run: UUID)

    private static let askedPrefix = "asked/"
    private static let toolRunPrefix = "tool/"

    public init?(_ id: AgentContextID) {
        if id.rawValue.hasPrefix(Self.askedPrefix) {
            let scoped = id.rawValue.dropFirst(Self.askedPrefix.count)
            guard let slash = scoped.firstIndex(of: "/"), let space = UUID(uuidString: String(scoped[..<slash]))
            else { return nil }
            let role = scoped[scoped.index(after: slash)...]
            guard !role.isEmpty, !role.contains("/") else { return nil }
            self = .asked(as: Role(String(role)), in: SpaceID(rawValue: space))
        } else if id.rawValue.hasPrefix(Self.toolRunPrefix) {
            let parts = id.rawValue.dropFirst(Self.toolRunPrefix.count).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 4, let space = UUID(uuidString: String(parts[0])), !parts[1].isEmpty,
                let run = UUID(uuidString: String(parts[2])), !parts[3].isEmpty
            else { return nil }
            self = .toolRun(String(parts[3]), calledBy: Role(String(parts[1])), in: SpaceID(rawValue: space), run: run)
        } else if let (space, conversation) = HailAgentAdapter.conversation(in: id) {
            self = .conversation(conversation, in: space)
        } else {
            return nil
        }
    }

    /// The space `agent` works in: refused for one in none.
    public static func space(of agent: AgentID) throws -> SpaceID {
        guard let context = AgentContext(agent.contextID) else { throw AgentInNoSpace(agent: agent) }
        return context.space
    }

    /// The space it's in.
    public var space: SpaceID {
        switch self {
        case .conversation(_, let space), .asked(_, let space), .toolRun(_, _, let space, _): space
        }
    }

    public var contextID: AgentContextID {
        switch self {
        case .conversation(let conversation, let space):
            HailAgentAdapter.contextID(for: conversation, in: space)
        case .asked(let role, let space):
            AgentContextID(Self.askedPrefix + space.rawValue.uuidString + "/" + role.rawValue)
        case .toolRun(let tool, let caller, let space, let run):
            AgentContextID(
                Self.toolRunPrefix + space.rawValue.uuidString + "/" + caller.rawValue + "/" + run.uuidString + "/"
                    + tool)
        }
    }
}

/// An agent working in no space, where one is needed.
public struct AgentInNoSpace: Error, Equatable, Sendable, CustomStringConvertible {
    public let agent: AgentID

    public var description: String { "\(agent) works in no space." }
}

extension Role {
    /// What Hail calls the agent a user's tool thinks with, for one run: with no hyphen, since Hail
    /// reads an agent's role up to its id's first hyphen.
    public static let toolRun = Role("toolrun")
}
