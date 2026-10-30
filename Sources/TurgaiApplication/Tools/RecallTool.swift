import AnyLanguageModel
import DistributedCluster
import Hail
import TurgaiDomain

/// Recalls what's remembered about the person the agent talks with: what it learned from earlier
/// conversations, most important first.
public struct RecallTool: HailCore.Tool {
    public typealias Input = EmptyToolInput

    let actorSystem: ClusterSystem
    let person: TurgaiDomain.UserID
    public let name = "recall"
    public let description = "Recall what you remember about the person you're talking with, from earlier conversations."

    public func effect(for input: Input) throws -> RecallEffect {
        RecallEffect(actorSystem: actorSystem, person: person)
    }

    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<RecallEffect>)
        async throws -> CallReturn
    {
        try await RecallEffect.run(in: token)
    }
}

/// Reads what's remembered about a person.
public struct RecallEffect: ScopedEffect, Sendable {
    public let name = "memory.recall"
    let actorSystem: ClusterSystem
    let person: TurgaiDomain.UserID

    public static func run(in token: borrowing EffectToken<Self>) async throws -> CallReturn {
        let (actorSystem, person) = token.withConfiguration { ($0.actorSystem, $0.person) }
        let user = try await User.resolve(on: actorSystem, userID: person)
        return CallReturn(.text(try await user.recalled()))
    }
}
