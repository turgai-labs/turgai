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

/// Who asked for what an admin then allows once: a person, themselves, or one actor's own work,
/// done for whoever it's for. What's allowed once goes to exactly the one that asked.
public enum Asker: Hashable, Codable, Sendable {
    case person
    case actor(CallActor)
}

/// Who a call is on behalf of, and the actors it went through to get here, the first first: each
/// while its code handles the call. It's what tells an actor a call came from its own handling,
/// and what makes calls that go round in a circle fail, with the circle as the reason, instead of
/// running until memory runs out.
public struct CallChain: Codable, Sendable, Equatable {
    /// Whoever started it, as they came in. It stays the same down the chain.
    public let scope: CallScope
    /// The conversation it happens in, when it happens in one: a turn's, or, for what an actor
    /// does itself, the one it was made in. It stays the same down the chain too.
    public let place: ConversationID?
    /// Who it's for, asking: its person, or an actor's own work, done for them. What an admin
    /// allows once goes to exactly the one that asked.
    public let asker: Asker
    public let actors: [CallActor]

    /// How deep calls may go.
    static let limit = 64

    /// A call no actor's code made, on behalf of `scope`, in `place`: the start of a chain its
    /// person makes.
    public static func start(_ scope: CallScope, in place: ConversationID?) -> CallChain {
        CallChain(scope: scope, place: place, asker: .person, actors: [])
    }

    /// The start of a chain of `actor`'s own work, its tasks and what it follows, on behalf of
    /// `scope`, whoever it's for, in `place`.
    public static func own(_ actor: CallActor, for scope: CallScope, in place: ConversationID?) -> CallChain {
        CallChain(scope: scope, place: place, asker: .actor(actor), actors: [])
    }

    /// The chain inside `actor`'s handling of a call that came through this one, refused once
    /// it's too deep. It's left as the handling ends, with the chain it was entered from.
    public func entering(_ actor: CallActor) throws(CallsTooDeep) -> CallChain {
        let next = CallChain(scope: scope, place: place, asker: asker, actors: actors + [actor])
        guard next.actors.count <= Self.limit else { throw CallsTooDeep(chain: next) }
        return next
    }

    /// Whether the call came through `actor`'s handling.
    public func contains(_ actor: CallActor) -> Bool {
        actors.contains(actor)
    }

    /// The chain the current task is in, carried with its calls to other nodes.
    @TaskLocal public static var current: CallChain?

    /// The chain the current task is in, entered by `actor` as it handles a call. A call in no
    /// chain is on behalf of no one, and is refused.
    public static func entering(_ actor: CallActor) throws -> CallChain {
        guard let current else { throw CallOnBehalfOfNoOne(actor: actor) }
        return try current.entering(actor)
    }
}

/// A call that no chain carried, so on behalf of no one: every call starts with someone.
public struct CallOnBehalfOfNoOne: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public let actor: CallActor

    public init(actor: CallActor) {
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
