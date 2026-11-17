import AnyLanguageModel
import Foundation
import Hail
import TurgaiDomain
import TurgaiHail

/// What an agent did in a conversation's turns, read from the agent's journal: every turn, a
/// compaction or not, under the conversation's own ids.
public enum ConversationTurns {
    /// The turns `events` tell that `links` names, each as the conversation's turn it was. One with
    /// no link, as a rerun after a restart leaves, wasn't one of the conversation's turns.
    public static func turns(
        from events: [AgentEvent], links: [AgentTurnID: TurgaiDomain.TurnID]
    ) throws(AgentHistory.InvalidEvent) -> [ConversationTurn] {
        let history = try AgentHistory(journal: events)
        let closed = history.closed.compactMap { turn in
            links[AgentTurnID(turn.id)].map { id in
                ConversationTurn(
                    id: id, message: text(turn.input.content), startedAt: turn.input.at, steps: turn.steps.map(step),
                    outcome: outcome(turn.outcome))
            }
        }
        let open = history.open.flatMap { turn in
            links[AgentTurnID(turn.id)].map { id in
                ConversationTurn(
                    id: id, message: text(turn.input.content), startedAt: turn.input.at, steps: turn.steps.map(step),
                    outcome: .running)
            }
        }
        return closed + (open.map { [$0] } ?? [])
    }

    private static func step(_ step: AgentHistory.Step) -> ReplyStep {
        switch step {
        case .called(let call, let at):
            .toolCalled(name: call.name, arguments: call.arguments.jsonString, at: at)
        case .resulted(let result, let at):
            .toolFinished(
                name: result.name, output: result.output.textRepresentation,
                failure: result.failureKind.map(HailRunMapper.failure),
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
