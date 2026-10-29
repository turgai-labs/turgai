import DistributedCluster
import TurgaiDomain

/// Who a call is on behalf of, and the actors it went through to get here, the first first: each
/// while its code handles the call. It's what tells an actor a call came from its own handling,
/// and what makes calls that go round in a circle fail, with the circle as the reason, instead of
/// running until memory runs out.
public struct CallChain: Codable, Sendable, Equatable {
    /// Whoever started it, as they came in. It stays the same down the chain.
    public let scope: CallScope
    /// The conversation it happens in, when it happens in one: a turn's, or, for what an object
    /// does itself, the one it was made in. It stays the same down the chain too.
    public let place: ConversationID?
    public let actors: [ObjectID]

    /// How deep calls may go.
    static let limit = 64

    /// A call no actor's code made, on behalf of `scope`, in `place`: the start of a chain.
    public static func start(_ scope: CallScope, in place: ConversationID?) -> CallChain {
        CallChain(scope: scope, place: place, actors: [])
    }

    /// The chain inside `actor`'s handling of a call that came through this one, refused once
    /// it's too deep. It's left as the handling ends, with the chain it was entered from.
    public func entering(_ actor: ObjectID) throws(CallsTooDeep) -> CallChain {
        let next = CallChain(scope: scope, place: place, actors: actors + [actor])
        guard next.actors.count <= Self.limit else { throw CallsTooDeep(chain: next) }
        return next
    }

    /// Whether the call came through `actor`'s handling.
    public func contains(_ actor: ObjectID) -> Bool {
        actors.contains(actor)
    }

    /// The chain the current task is in, carried with its calls to other nodes.
    @TaskLocal public static var current: CallChain?

    /// The chain the current task is in, entered by `actor` as it handles a call. A call in no
    /// chain is on behalf of no one, and is refused.
    public static func entering(_ actor: ObjectID) throws -> CallChain {
        guard let current else { throw CallOnBehalfOfNoOne(actor: actor) }
        return try current.entering(actor)
    }
}

/// A call that no chain carried, so on behalf of no one: every call starts with someone.
public struct CallOnBehalfOfNoOne: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public let actor: ObjectID

    public init(actor: ObjectID) {
        self.actor = actor
    }

    public var description: String { "a call to \(actor) is on behalf of no one" }
}

/// Calls that went deeper than a chain may go.
public struct CallsTooDeep: Error, Sendable, Equatable, CustomStringConvertible {
    public let chain: CallChain

    public var description: String {
        "calls went \(chain.actors.count) deep: "
            + (chain.actors.prefix(6).map(\.description) + (chain.actors.count > 6 ? ["…"] : []))
            .joined(separator: " → ")
    }
}

extension ClusterSystemSettings {
    /// Carries the call chain with remote calls, so a call on another node continues it. Every
    /// node that runs Turgai's agents or objects declares it.
    public mutating func propagateCallChain() {
        propagateTaskLocal(CallChain.$current, as: "turgai.call-chain")
    }
}
