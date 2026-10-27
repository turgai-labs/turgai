import DiscoverableActors
import Distributed
import DistributedCluster

/// Any discoverable object, held without knowing its Swift type.
public typealias DiscoverableObject = $DiscoverableActor<ClusterSystem>

extension DistributedReception.Key where Guest == DiscoverableObject {
    /// Where objects check in with the cluster receptionist. Only objects a model starts from check
    /// in: one reachable through their actions is found by walking to it. Whether a caller may see
    /// or use one is the object's to say, when it's called.
    public static var objects: Self { Self(id: "turgai.objects") }

    /// Where virtual actors check in, found by the name their id gives them without being asked what
    /// they are, which would start them: whoever offers them lists them, as the catalog doesn't.
    public static var virtualObjects: Self { Self(id: "turgai.objects.virtual") }
}
