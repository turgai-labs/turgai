import DistributedCluster
import Foundation
import Hail

/// What one turn did: its tool calls, with what each returned, and its answer.
struct RecordedTurn: Sendable {
    struct Call: Sendable {
        let name: String
        let arguments: String
        let output: String
        let failed: Bool
    }

    var calls: [Call] = []
    var answer = ""
    /// The context the turn's last model request used, as the provider reported it.
    var context: ContextUsage?

    /// Sends `text` to the agent, recording the turn from its updates.
    static func send(_ text: String, to agent: Agent, on system: ClusterSystem) async throws -> RecordedTurn {
        let stream = AgentStream<String>(actorSystem: system)
        let recording = Task {
            var turn = RecordedTurn()
            var requested: [String: String] = [:]
            for await update in stream.updates {
                switch update {
                case .toolRequested(let call, _):
                    requested[call.id] = call.arguments.jsonString
                case .toolCompleted(let result, _):
                    turn.calls.append(
                        Call(
                            name: result.name, arguments: requested[result.toolCallID] ?? "",
                            output: result.output.textRepresentation, failed: result.failureKind != nil))
                case .responseRecorded(let content, _):
                    turn.answer = content
                default:
                    break
                }
            }
            return turn
        }
        defer { stream.finish() }
        try await stream.send(text, message: .text(sender: "user", content: text, timestamp: Date()), to: agent)
        stream.finish()
        var turn = await recording.value
        turn.context = try? await agent.contextSnapshot.contextUsage
        return turn
    }

    var transcript: String {
        calls.map { "--- \($0.name) \($0.arguments.prefix(1200))\n=> \($0.output.prefix(400))\n" }.joined()
            + "=== answer: \(answer.prefix(400))\n"
            + (context.map { "=== context: \($0.usedTokens) of \($0.limitTokens) tokens\n" } ?? "")
    }
}
