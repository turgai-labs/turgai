import Foundation

/// One turn of the agent, as the turns window shows it: the message that started it, each step,
/// and how it ended.
public struct TurnRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: TurnID
    public let message: String
    public let startedAt: Date
    public var steps: [TurnStep]
    public var outcome: TurnOutcome

    public init(id: TurnID, message: String, startedAt: Date, steps: [TurnStep] = [], outcome: TurnOutcome = .running) {
        self.id = id
        self.message = message
        self.startedAt = startedAt
        self.steps = steps
        self.outcome = outcome
    }
}

/// One thing the agent did during a turn.
public struct TurnStep: Codable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        /// A tool it called, with its arguments as the model wrote them.
        case toolCalled(name: String, arguments: String)
        /// A tool call's result; `failure` says why it failed, when it did.
        case toolFinished(name: String, output: String, failure: String?)
        /// What the runtime told the model in the turn, in the words it was told.
        case noticed(words: String)
    }

    public let at: Date
    public let kind: Kind

    public init(at: Date, kind: Kind) {
        self.at = at
        self.kind = kind
    }
}

/// How a turn ended, or that it hasn't yet.
public enum TurnOutcome: Codable, Equatable, Sendable {
    case running
    case replied(String, at: Date)
    case failed(String, at: Date)
    case cancelled(at: Date)
    case interrupted(at: Date)
}
