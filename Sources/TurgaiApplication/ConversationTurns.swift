import AnyLanguageModel
import Hail
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The agent's transcript as turns, for watching what it did: a message starts a turn, its tool
/// calls and results are the steps, and a reply or a failure ends it.
public enum ConversationTurns {
    public static func fold(_ transcript: [ChatMessage]) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        for message in transcript {
            switch message {
            case .text(_, let content, let at):
                turns.append(ConversationTurn(message: content, startedAt: at))
            case .assistantToolCall(let round, let at):
                for call in round.calls {
                    turns.appendStep(.toolCalled(name: call.name, arguments: call.arguments.jsonString, at: at))
                }
            case .toolCall(let calls, let at):
                for call in calls {
                    turns.appendStep(.toolCalled(name: call.name, arguments: call.arguments.jsonString, at: at))
                }
            case .toolResult(_, let name, let output, let failure, let at):
                turns.appendStep(
                    .toolFinished(name: name, output: output.textRepresentation, failure: failure?.rawValue, at: at))
            case .response(_, let content, let at):
                turns.end(.replied(text(content), at: at))
            case .failure(let error, let at):
                turns.end(.failed(String(describing: error), at: at))
            case .decisionRequest, .decisionResolved:
                break
            }
        }
        return turns
    }

    private static func text(_ content: GeneratedContent) -> String {
        if case .string(let value) = content.kind { return value }
        return content.jsonString
    }
}

extension [ConversationTurn] {
    fileprivate mutating func appendStep(_ step: ReplyStep) {
        guard !isEmpty else { return }
        self[count - 1].steps.append(step)
    }

    fileprivate mutating func end(_ outcome: ConversationTurn.Outcome) {
        guard !isEmpty else { return }
        self[count - 1].outcome = outcome
    }
}
