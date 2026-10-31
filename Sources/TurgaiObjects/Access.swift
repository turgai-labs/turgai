import DiscoverableActors
import Distributed
import DistributedCluster
import TurgaiCalls
import TurgaiDomain


/// An object that says who may read it and who may write it. An object that doesn't is refused
/// every call: each kind of object says its own.
public protocol AccessControlled: DistributedActor where ActorSystem == ClusterSystem {
    /// Who may read it and who may write it, for a call through `chain`.
    func access(for chain: CallChain) -> Access
}

extension AccessControlled {
    /// Refuses a call, before it runs, whose chain may not read it.
    nonisolated func checkReading() async throws {
        let chain = CallChain.current
        let object = id.virtualActorID.map(ObjectID.virtual) ?? .actor(id, type: nil)
        try await whenLocal { local in
            guard let chain else { throw CallOnBehalfOfNoOne(actor: object.callActor) }
            guard local.access(for: chain).allows(chain, .read) else { throw NotAllowed(.read) }
        }
    }
}

extension ClusterSystemSettings {
    /// Checks every call to an object before it runs, on whichever node it lives: a call from
    /// another node, or one through a reference here. A call is on someone's behalf, who may read
    /// the object; one that changes it, the object refuses as it decides the change, unless they
    /// may write it. An object that doesn't say who may read it is refused.
    public mutating func checkObjectAccess() {
        remoteCall.incomingCallFilter = { actor, _ in
            if let object = actor as? any AccessControlled {
                try await object.checkReading()
            } else if actor is any DiscoverableActor {
                throw NotAllowed(.read)
            }
        }
    }
}
