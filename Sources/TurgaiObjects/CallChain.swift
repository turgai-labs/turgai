import DistributedCluster

/// The actors a call went through to get here, the first first: each while its code handles the
/// call. It's what tells an actor a call came from its own handling, and what makes calls that go
/// round in a circle fail, with the circle as the reason, instead of running until memory runs out.
public struct CallChain: Codable, Sendable, Equatable {
    public let actors: [ObjectID]

    /// How deep calls may go.
    static let limit = 64

    /// A call no actor's code made: the start of a chain.
    public static let start = CallChain(actors: [])

    /// The chain inside `actor`'s handling of a call that came through this one, refused once
    /// it's too deep. It's left as the handling ends, with the chain it was entered from.
    public func entering(_ actor: ObjectID) throws(CallsTooDeep) -> CallChain {
        let next = CallChain(actors: actors + [actor])
        guard next.actors.count <= Self.limit else { throw CallsTooDeep(chain: next) }
        return next
    }

    /// Whether the call came through `actor`'s handling.
    public func contains(_ actor: ObjectID) -> Bool {
        actors.contains(actor)
    }

    /// The chain the current task is in, carried with its calls to other nodes.
    @TaskLocal public static var current: CallChain?

    /// The chain the current task is in: none is the start of one.
    public static var ongoing: CallChain { current ?? .start }
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
