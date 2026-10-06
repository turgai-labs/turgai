import Foundation
import Hail

/// Something to ask for, and how to tell an object answered it.
struct EvalTask: Sendable {
    let request: String
    let followUp: String
    /// Whether an object's reply answers the follow-up.
    let answered: @Sendable (String) -> Bool

    static let all = [
        EvalTask(
            request: "Make a counter for my coffee cups: I can add a cup, ask how many I had, and reset it.",
            followUp: "I had two cups just now. How many have I had?", answered: has("2")),
        EvalTask(
            request: "Make a shopping list I can add things to, cross things off, and ask what's still on it.",
            followUp: "Put milk and eggs on it, then cross off milk. What's still on it?",
            answered: { $0.lowercased().contains("egg") && !$0.lowercased().contains("milk") }),
        EvalTask(
            request: "Make two counters, one for coffee and one for tea, that work the same way.",
            followUp: "Count one coffee and two teas. How many teas so far?", answered: has("2")),
        EvalTask(
            request:
                "Make a manager, Ann, with a budget of 1000, and a worker, Bob, earning 3000. Bob can ask Ann for a raise, and she approves it while her budget lasts.",
            followUp: "Bob asks Ann for a raise of 200. What does Bob earn now?", answered: has("3200")),
    ]

    private static func has(_ words: String...) -> @Sendable (String) -> Bool {
        { reply in words.allSatisfy { reply.lowercased().contains($0) } }
    }

    struct Result {
        let passed: Bool
        let line: String
        let transcript: String
    }

    /// Asks a fresh agent on a fresh node, then the follow-up, and checks the objects' replies.
    func run(with model: AgentModel) async -> Result {
        let started = Date()
        var turns: [RecordedTurn] = []
        var failure: String?
        do {
            let node = try await EvalNode.start(model: model)
            defer { node.stop() }
            let agent = try await node.freshAgent()
            turns.append(try await RecordedTurn.send(request, to: agent, on: node.system))
            turns.append(try await RecordedTurn.send(followUp, to: agent, on: node.system))
        } catch {
            failure = String(describing: error)
        }
        // An object's own reply, from a tool of one object, such as `coffee-counter_howMany`.
        let replies = turns.dropFirst().flatMap(\.calls).filter { !$0.name.hasPrefix("objects_") && !$0.failed }.map(\.output)
        let passed = failure == nil && replies.contains(where: answered)
        let calls = turns.flatMap(\.calls)
        let note = failure.map { "  (\($0.prefix(160)))" } ?? ""
        return Result(
            passed: passed,
            line:
                "\(passed ? "PASS" : "FAIL")  calls \(calls.count)  errors \(calls.filter(\.failed).count)  context \(turns.map { $0.context.map { "\($0.usedTokens)" } ?? "?" }.joined(separator: "/"))  \(Int(Date().timeIntervalSince(started)))s  \(request.prefix(50))\(note)",
            transcript: (failure.map { "failed: \($0)\n" } ?? "") + turns.enumerated().map { "=== turn \($0 + 1)\n" + $1.transcript }.joined()
        )
    }
}
