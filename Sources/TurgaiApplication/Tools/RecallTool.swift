import AnyLanguageModel
import DistributedCluster
import Hail
import TurgaiDomain
import TurgaiMemory
import TurgaiPeople

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Recalls what's remembered about the person the agent talks with: what it learned from earlier
/// conversations, most important first.
public struct RecallTool: HailCore.Tool {
    public typealias Input = EmptyToolInput

    let actorSystem: ClusterSystem
    /// The human it's about: the person it talks with, and everyone linked to them.
    let persons: [TurgaiDomain.UserID]
    public let name = "recall"
    public let description =
        "Recall what you remember about the person you're talking with, from earlier conversations."

    public func effect(for input: Input) throws -> RecallEffect {
        RecallEffect(actorSystem: actorSystem, persons: persons)
    }

    public func run(_ input: Input, in scope: borrowing ToolScope<Never>, token: borrowing EffectToken<RecallEffect>)
        async throws -> CallReturn
    {
        try await RecallEffect.run(in: token)
    }
}

/// Reads what's remembered about a human: by each of their linked persons who remembers, each fact
/// once, the earliest learned.
public struct RecallEffect: ScopedEffect, Sendable {
    public let name = "memory.recall"
    let actorSystem: ClusterSystem
    let persons: [TurgaiDomain.UserID]

    public static func run(in token: borrowing EffectToken<Self>) async throws -> CallReturn {
        let (actorSystem, persons) = token.withConfiguration { ($0.actorSystem, $0.persons) }
        var facts: [MemoryFact] = []
        for person in persons {
            let user = try await User.identified(by: person, on: actorSystem)
            if try await user.recallable() { facts += try await user.remembered().facts }
        }
        var recalled: [MemoryFact] = []
        for fact in Remembered(facts).facts where !recalled.contains(where: { $0.isSame(as: fact) }) {
            recalled.append(fact)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(recalled.map(Recalled.init))
        return .data(ToolData(body: body, contentType: "application/json"))
    }
}

/// A fact as a recall gives it: how the person is related to whom or what, and the day it was
/// learned.
struct Recalled: Encodable, Equatable {
    let relation: MemoryRelation
    let to: String
    let learned: String

    init(_ fact: MemoryFact) {
        self.relation = fact.relation
        self.to = fact.to.rawValue
        self.learned = fact.learned.at.formatted(.iso8601.year().month().day())
    }
}
