import AnyLanguageModel
import Foundation
import Hail
import TurgaiDomain

/// The agent's history as turns, for watching what it did. Turns a compaction folded into the
/// summary are no longer there.
public enum ConversationTurns {
    public static func turns(of history: AgentHistory) throws(ForeignTurn) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        for turn in history.closed { turns.append(try closed(turn)) }
        if let turn = history.open { turns.append(try open(turn)) }
        return turns
    }

    /// A turn in the agent's history that isn't one of the conversation's: its ID isn't one
    /// Turgai gave it.
    public struct ForeignTurn: Error, Sendable, CustomStringConvertible {
        public let id: Hail.TurnID
        public var description: String { "The agent's turn \(id) isn't one of the conversation's." }
    }

    /// The conversation's turn a Hail turn is: Turgai starts each with its own ID.
    private static func id(of turn: Hail.TurnID) throws(ForeignTurn) -> TurgaiDomain.TurnID {
        guard let id = UUID(uuidString: turn.rawValue) else { throw ForeignTurn(id: turn) }
        return TurgaiDomain.TurnID(rawValue: id)
    }

    private static func closed(_ turn: AgentHistory.ClosedTurn) throws(ForeignTurn) -> ConversationTurn {
        ConversationTurn(
            id: try id(of: turn.id), message: text(turn.input.content), startedAt: turn.input.at,
            steps: turn.steps.map(step),
            outcome: outcome(turn.outcome))
    }

    private static func open(_ turn: AgentHistory.OpenTurn) throws(ForeignTurn) -> ConversationTurn {
        ConversationTurn(
            id: try id(of: turn.id), message: text(turn.input.content), startedAt: turn.input.at,
            steps: turn.steps.map(step),
            outcome: .running)
    }

    private static func step(_ step: AgentHistory.Step) -> ReplyStep {
        switch step {
        case .called(let call, let at):
            .toolCalled(name: call.name, arguments: call.arguments.jsonString, at: at)
        case .resulted(let result, let at):
            .toolFinished(
                name: result.name, output: result.output.textRepresentation, failure: result.failureKind?.rawValue,
                at: at)
        case .noticed(let notice, let at):
            .noticed(words: notice.words, at: at)
        }
    }

    private static func outcome(_ outcome: AgentHistory.Outcome) -> ConversationTurn.Outcome {
        switch outcome {
        case .replied(let reply): .replied(text(reply.content), at: reply.at)
        case .failed(let failure): .failed(String(describing: failure.error), at: failure.at)
        case .cancelled(let at): .cancelled(at: at)
        case .interrupted(let at): .interrupted(at: at)
        }
    }

    private static func text(_ content: GeneratedContent) -> String {
        if case .string(let value) = content.kind { return value }
        return content.jsonString
    }
}
