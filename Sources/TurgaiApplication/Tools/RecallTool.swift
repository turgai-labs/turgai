import AnyLanguageModel
import DistributedCluster
import Hail
import TurgaiDomain
import TurgaiMemory
import TurgaiPeople

/// Recalls what's remembered about the person the agent talks with: what it learned from earlier
/// conversations, most important first.
public struct RecallTool: HailCore.Tool {
    public typealias Input = EmptyToolInput

    let actorSystem: ClusterSystem
    /// The human it's about: the person it talks with, and everyone linked to them.
    let persons: [TurgaiDomain.UserID]
    public let name = "recall"
    public let description = "Recall what you remember about the person you're talking with, from earlier conversations."

    public func effect(for input: Input) throws -> RecallEffect {
        RecallEffect(actorSystem: actorSystem, persons: persons)
    }

    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<RecallEffect>)
        async throws -> CallReturn
    {
        try await RecallEffect.run(in: token)
    }
}

/// Reads what's remembered about a human: by each of their linked persons who remembers, in one
/// tree.
public struct RecallEffect: ScopedEffect, Sendable {
    public let name = "memory.recall"
    let actorSystem: ClusterSystem
    let persons: [TurgaiDomain.UserID]

    public static func run(in token: borrowing EffectToken<Self>) async throws -> CallReturn {
        let (actorSystem, persons) = token.withConfiguration { ($0.actorSystem, $0.persons) }
        var facts: [MemoryFact] = []
        for person in persons {
            let user = try await User.resolve(on: actorSystem, userID: person)
            if try await user.recallable() { facts += try await user.remembered().facts }
        }
        return CallReturn(.text(MemoryRetrieval.recalled(MemoryTree(facts))))
    }
}
