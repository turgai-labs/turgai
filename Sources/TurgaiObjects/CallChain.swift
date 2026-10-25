import DistributedCluster
import TurgaiDomain
import VirtualActors

extension ClusterSystemSettings {
    /// Carries the call chain with remote calls, so a call on another node continues it. Every
    /// node that runs Turgai's agents or objects declares it.
    public mutating func propagateCallChain() {
        propagateTaskLocal(CallChain.$current, as: "turgai.call-chain")
    }
}

extension ActorIdentity {
    /// The identity of the virtual actor with `id`.
    public init(_ id: VirtualActorID) {
        self.init(rawValue: id.rawValue)
    }
}
