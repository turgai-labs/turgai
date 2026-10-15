import AnyLanguageModel
import DistributedCluster
import Hail
import TurgaiDomain

/// Recalls what's remembered about the person the agent talks with: what it learned from earlier
/// conversations, found by topic, when the model asks for it.
public struct RecallTool: HailCore.Tool {
    @Generable(description: "What to recall.")
    public struct Input: Sendable {
        @Guide(description: "The topic, in words.")
        public let topic: String
    }

    let actorSystem: ClusterSystem
    let person: TurgaiDomain.UserID
    public let name = "recall"
    public let description = "Recall what you remember about the person you're talking with, on a topic, from earlier conversations."

    public func effect(for input: Input) throws -> RecallEffect {
        RecallEffect(actorSystem: actorSystem, person: person, topic: input.topic)
    }

    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<RecallEffect>) async throws -> CallReturn {
        try await RecallEffect.run(in: token)
    }
}

/// Reads what's remembered about a person on a topic.
public struct RecallEffect: ScopedEffect, Sendable {
    public let name = "memory.recall"
    let actorSystem: ClusterSystem
    let person: TurgaiDomain.UserID
    let topic: String

    public static func run(in token: borrowing EffectToken<Self>) async throws -> CallReturn {
        let (actorSystem, person, topic) = token.withConfiguration { ($0.actorSystem, $0.person, $0.topic) }
        let user = try await User.resolve(on: actorSystem, userID: person)
        return CallReturn(.text(try await user.recall(topic)))
    }
}
