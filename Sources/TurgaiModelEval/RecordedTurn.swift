import AnyLanguageModel
import DistributedCluster
import Foundation
import Hail
import TurgaiHail

/// What one turn did: its tool calls, with what each returned, and its answer.
struct RecordedTurn: Sendable {
    struct Call: Sendable {
        let id: String
        let name: String
        let arguments: String
        var output: String
        var completed: Bool
        let failed: Bool
    }

    var calls: [Call] = []
    var answer = ""
    var failure: String?
    /// The context the turn's last model request used, as the provider reported it.
    var context: ContextUsage?

    /// Sends `text` to the agent, recording the turn from its updates.
    static func send(_ text: String, to agent: Agent, on system: ClusterSystem) async -> RecordedTurn {
        let stream = AgentStream<AgentReply>(actorSystem: system)
        let recording = Task {
            var turn = RecordedTurn()
            var requested: [String: String] = [:]
            for await update in stream.updates {
                switch update {
                case .toolRequested(let call, _):
                    requested[call.id] = call.arguments.jsonString
                    turn.calls.append(
                        Call(
                            id: call.id, name: call.name, arguments: call.arguments.jsonString,
                            output: "", completed: false, failed: false))
                case .toolCompleted(let result, _):
                    if let index = turn.calls.firstIndex(where: { $0.id == result.toolCallID }) {
                        turn.calls[index].output = result.output.textRepresentation
                        turn.calls[index].completed = true
                        turn.calls[index] = Call(
                            id: turn.calls[index].id, name: turn.calls[index].name,
                            arguments: requested[result.toolCallID] ?? turn.calls[index].arguments,
                            output: result.output.textRepresentation, completed: true,
                            failed: result.failureKind != nil)
                    } else {
                        turn.calls.append(
                            Call(
                                id: result.toolCallID, name: result.name, arguments: requested[result.toolCallID] ?? "",
                                output: result.output.textRepresentation, completed: true,
                                failed: result.failureKind != nil))
                    }
                case .responseRecorded(let reply, _):
                    turn.answer = reply.text
                default:
                    break
                }
            }
            return turn
        }
        do {
            try await stream.send(text, to: agent)
        } catch {
            // The model may fail after several useful tool calls. Keep those calls in the trace.
            stream.finish()
            var partial = await recording.value
            partial.failure = String(describing: error)
            partial.context = try? await agent.contextSnapshot.contextUsage
            return partial
        }
        stream.finish()
        var turn = await recording.value
        turn.context = try? await agent.contextSnapshot.contextUsage
        return turn
    }

    var transcript: String {
        calls.map { "--- \($0.name) \($0.arguments)\n=> \($0.output)\n" }.joined()
            + "=== answer: \(answer)\n"
            + (failure.map { "=== failure: \($0)\n" } ?? "")
            + (context.map { "=== context: \($0.usedTokens) of \($0.limitTokens) tokens\n" } ?? "")
    }
}
