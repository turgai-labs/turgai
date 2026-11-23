import AttributedCalls
import DiscoverableActors
import Distributed
import DistributedCluster
import TurgaiCalls
import TurgaiDomain
import VirtualActors

/// An object that says who may read it and who may write it. An object that doesn't is refused
/// every call: each kind of object says its own.
public protocol AccessControlled: DistributedActor where ActorSystem == ClusterSystem {
    /// Who may read it and who may write it, for a call through `chain`: asked wherever it runs,
    /// as any of its calls is, and checked as one too.
    distributed func access(for chain: CallChain) -> Access
}

/// A call as the actor it reached sees it: what its work may do, as its space said, and the actor
/// that made it, as the actor system says.
struct Reached {
    let chain: CallChain
    /// The actor that made the call: none when no actor did.
    let caller: CallActor?

    var scope: CallScope { chain.scope }
    var place: ConversationID? { chain.place }

    /// The call the current task is handling: refused when nothing says whom it's for.
    static func current(at actor: CallActor) throws -> Reached {
        guard let chain = CallChain.current else { throw CallOnBehalfOfNoOne(actor: actor) }
        return Reached(chain: chain, caller: Call.caller.map(CallActor.virtual))
    }
}

extension Access {
    /// Whether `call` may go as far as `level`: whoever asked may, or the actor calling may.
    func allows(_ call: Reached, _ level: AccessLevel) -> Bool {
        allows(call.scope, calledBy: call.caller, level)
    }
}

/// What a node's objects ask whoever decides for their spaces. Whoever builds the node says how:
/// an app with no one else deciding for it decides from what the call carries, ``default``; one
/// where a space decides asks it, as things are when it's asked.
public struct ObjectCallDecisions: Sendable {
    /// Whether work with `chain`, calling through `caller`, may go as far as a level with
    /// `object`, whose access says who may use it.
    public let decide:
        @Sendable (
            _ access: Access, _ level: AccessLevel, _ object: ObjectID, _ chain: CallChain, _ caller: CallActor?,
            _ system: ClusterSystem
        ) async throws -> Bool
    /// What work that starts for an asker, in a space, may do: asked when work reaches one of the
    /// space's actors with who asked and nothing about what they may.
    public let opening: @Sendable (_ asker: Party, _ space: SpaceID, _ system: ClusterSystem) async throws -> CallScope

    public init(
        decide:
            @escaping @Sendable (Access, AccessLevel, ObjectID, CallChain, CallActor?, ClusterSystem) async throws
            -> Bool,
        opening: @escaping @Sendable (Party, SpaceID, ClusterSystem) async throws -> CallScope
    ) {
        self.decide = decide
        self.opening = opening
    }

    /// From what the call carries, as it was said when its work started; and work with nothing
    /// said may nothing but what's shared with whoever asked.
    public static let `default` = ObjectCallDecisions(
        decide: { access, level, _, chain, caller, _ in access.allows(chain.scope, calledBy: caller, level) },
        opening: { asker, space, _ in CallScope(asker, in: space, may: .none, groups: [], allowed: []) })
}

/// Holds what a node's objects ask whoever decides for their spaces, where they reach it.
public actor ObjectAccess: Plugin {
    public static let pluginKey: Key = "$objectAccess"

    public nonisolated var key: Key { Self.pluginKey }

    nonisolated let decisions: ObjectCallDecisions

    init(_ decisions: ObjectCallDecisions) {
        self.decisions = decisions
    }

    public func start(_ system: ClusterSystem) async throws {}

    public func stop(_ system: ClusterSystem) async {}
}

extension ClusterSystem {
    /// What this node's objects ask whoever decides for their spaces.
    var objectCallDecisions: ObjectCallDecisions {
        settings.plugins[ObjectAccess.pluginKey]?.decisions ?? .default
    }
}

extension AccessControlled {
    /// Refuses a call, before it runs, whose chain may not read it, as `decisions` decide. Its own
    /// work reaches it always.
    nonisolated func checkReading(_ decisions: ObjectCallDecisions) async throws {
        let object = id.virtualActorID.map(ObjectID.virtual) ?? .actor(id, type: nil)
        let call = try Reached.current(at: object.callActor)
        if let own = id.virtualActorID, call.scope.asker.actorID == own { return }
        let access = try await access(for: call.chain)
        guard try await decisions.decide(access, .read, object, call.chain, call.caller, actorSystem) else {
            throw NotAllowed(.read)
        }
    }
}

extension ClusterSystemSettings {
    /// Checks every call to an actor of this node before it runs, on whichever node it lives: a
    /// call from another node, or one through a reference here.
    ///
    /// Each call says who made it and who asked, and an actor a space owns takes calls from its
    /// space's side. One from outside the space runs when it carries what its space said whoever
    /// asked may do; with nothing said, its space is asked, for whoever asked, and refuses someone
    /// who isn't in it. The same for work that comes back to one of a space's objects later, such
    /// as a schedule that's due: its space says then what it may do.
    ///
    /// A call to an object is then checked: whoever asked may read the object, as `decisions`
    /// decide; one that changes it, the object refuses as it decides the change, unless they may
    /// write it. An object that doesn't say who may read it is refused.
    public mutating func checkObjectAccess(deciding decisions: ObjectCallDecisions = .default) {
        attributeCalls()
        plugins.install(plugin: ObjectAccess(decisions))
        let outside: OutsideCalls = { asked, actor, run in
            guard let space = asked.owner.space, let system = actor.actorSystem as? ClusterSystem else {
                throw OutsideCaller(owner: asked.owner, caller: asked.caller)
            }
            if let chain = CallChain.current {
                // What another space said doesn't count here.
                guard chain.scope.space == space else { throw NotAllowed(.read) }
                return try await run()
            }
            guard let asker = asked.askedBy else { throw CallOnBehalfOfNoOne(actor: .virtual(asked.actor)) }
            let scope = try await decisions.opening(try Party(asker), space, system)
            try await CallChain.$current.withValue(.start(scope, in: nil), operation: run)
        }
        remoteCall.incomingCallInterceptor = { actor, target, call in
            try await Call.receiving(by: actor, target: target, outside: outside) {
                guard let object = actor as? any AccessControlled else {
                    if actor is any DiscoverableActor { throw NotAllowed(.read) }
                    return try await call()
                }
                // Work that came back to it with who asked and nothing about what they may: its
                // space says, now.
                if CallChain.current == nil, let asker = Call.askedBy,
                    let space = object.id.virtualActorID?.owner?.space
                {
                    let scope = try await decisions.opening(try Party(asker), space, object.actorSystem)
                    return try await CallChain.$current.withValue(.start(scope, in: nil)) {
                        try await object.checkReading(decisions)
                        try await call()
                    }
                }
                try await object.checkReading(decisions)
                try await call()
            }
        }
    }
}
