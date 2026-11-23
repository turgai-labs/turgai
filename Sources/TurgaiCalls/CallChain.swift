import DistributedCluster
import TurgaiDomain
import VirtualActors

/// An actor a call reaches: a virtual one, by its id, the same wherever and whenever it runs; or
/// any other, by its id, which it is while it lives.
public enum CallActor: Hashable, Codable, Sendable, CustomStringConvertible {
    case virtual(VirtualActorID)
    case actor(ClusterSystem.ActorID)

    /// How it's written in what a chain says: the last part of a virtual actor's id, or where any
    /// other one is.
    public var description: String {
        switch self {
        case .virtual(let id): id.rawValue.split(separator: "/").last.map(String.init) ?? id.rawValue
        case .actor(let id): "\(id.node)\(id.path)"
        }
    }
}

/// What a piece of work may do, and where it happens: what its space said whoever asked may do
/// when the work started, and the conversation it's in, when it's in one. Everything the work calls
/// has it, and nothing keeps it after. Who made each call, who asked, and how far the calls went,
/// the actor system says itself.
public struct CallChain: Codable, Sendable, Equatable {
    /// Whoever asked, and what they may do, as their space said when the work started.
    public let scope: CallScope
    /// The conversation it happens in, when it happens in one: a turn's, or, for what an actor
    /// does itself, the one it was made in.
    public let place: ConversationID?

    /// The start of a piece of work for `scope`, in `place`.
    public static func start(_ scope: CallScope, in place: ConversationID?) -> CallChain {
        CallChain(scope: scope, place: place)
    }

    /// The same work with `scope`, as whoever decides for whoever asked has it now: in the same
    /// place.
    public func settled(as scope: CallScope) -> CallChain {
        CallChain(scope: scope, place: place)
    }

    /// What the work the current task is in may do, carried with its calls to other nodes.
    @TaskLocal public static var current: CallChain?
}

/// A call that carried nothing about whom it's for, so on behalf of no one: every call starts with
/// someone.
public struct CallOnBehalfOfNoOne: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public let actor: CallActor

    public init(actor: CallActor) {
        self.actor = actor
    }

    public var description: String { "a call to \(actor) is on behalf of no one" }
}

extension ClusterSystemSettings {
    /// Carries what a piece of work may do with its calls to other nodes. Every node that runs
    /// Turgai's agents or objects declares it.
    public mutating func propagateCallChain() {
        propagateTaskLocal(CallChain.$current, as: "turgai.call-chain")
    }
}
