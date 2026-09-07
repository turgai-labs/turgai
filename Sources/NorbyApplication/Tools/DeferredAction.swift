#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The work a durable schedule or timer performs when it fires.
public enum DeferredAction: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case notify
        case promptAgent = "prompt_agent"
    }

    /// Sends the supplied message to the conversation when the action fires.
    case notify(message: String)

    /// Delivers the supplied instruction as a new user message to the agent
    /// when the action fires.
    case promptAgent(instruction: String)

    public var kind: Kind {
        switch self {
        case .notify:
            .notify
        case .promptAgent:
            .promptAgent
        }
    }

    public var content: String {
        switch self {
        case .notify(let message):
            message
        case .promptAgent(let instruction):
            instruction
        }
    }

    public init(kind: Kind, content: String) {
        switch kind {
        case .notify:
            self = .notify(message: content)
        case .promptAgent:
            self = .promptAgent(instruction: content)
        }
    }
}
