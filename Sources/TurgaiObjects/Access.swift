import DiscoverableActors
import Distributed
import DistributedCluster
import AttributedCalls
import TurgaiCalls
import TurgaiDomain

/// An object that says who may read it and who may write it. An object that doesn't is refused
/// every call: each kind of object says its own.
public protocol AccessControlled: DistributedActor where ActorSystem == ClusterSystem {
    /// Who may read it and who may write it, for a call through `chain`: asked wherever it runs,
    /// as any of its calls is, and checked as one too.
    distributed func access(for chain: CallChain) -> Access
}

/// How a call into an object is decided: whether a call through a chain may go as far as a level
/// with something whose access says who may use it. Whoever builds the node says how: an app with
/// no one else deciding for it decides from what the call carries, ``default``; one where a space
/// decides asks it, as things are when the call is made.
public struct ObjectCallDecisions: Sendable {
    let decide:
        @Sendable (_ access: Access, _ level: AccessLevel, _ chain: CallChain, _ system: ClusterSystem)
            async throws -> Bool

    public init(
        decide: @escaping @Sendable (Access, AccessLevel, CallChain, ClusterSystem) async throws -> Bool
    ) {
        self.decide = decide
    }

    /// From what the call carries: its scope as it was settled when its chain started.
    public static let `default` = ObjectCallDecisions { access, level, chain, _ in access.allows(chain, level) }
}

extension AccessControlled {
    /// Refuses a call, before it runs, whose chain may not read it, as `decisions` decide.
    nonisolated func checkReading(_ decisions: ObjectCallDecisions) async throws {
        let object = id.virtualActorID.map(ObjectID.virtual) ?? .actor(id, type: nil)
        guard let chain = CallChain.current else { throw CallOnBehalfOfNoOne(actor: object.callActor) }
        let access = try await access(for: chain)
        guard try await decisions.decide(access, .read, chain, actorSystem) else { throw NotAllowed(.read) }
    }
}

extension ClusterSystemSettings {
    /// Checks every call to an actor of this node before it runs, on whichever node it lives: a
    /// call from another node, or one through a reference here.
    ///
    /// Each call says who made it and who it's for, and an actor another owns takes calls only from
    /// its owner's side. A
    /// call to an object is on someone's behalf, who may read the object, as `decisions` decide; one
    /// that changes it, the object refuses as it decides the change, unless they may write it. An
    /// object that doesn't say who may read it is refused.
    public mutating func checkObjectAccess(deciding decisions: ObjectCallDecisions = .default) {
        attributeCalls()
        remoteCall.incomingCallInterceptor = { actor, _, call in
            try await Call.receiving(by: actor) {
                if let object = actor as? any AccessControlled {
                    try await object.checkReading(decisions)
                } else if actor is any DiscoverableActor {
                    throw NotAllowed(.read)
                }
                try await call()
            }
        }
    }
}
