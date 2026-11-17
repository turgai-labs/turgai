import DiscoverableActors
import Distributed
import DistributedCluster

/// Any discoverable object, held without knowing its Swift type.
public typealias DiscoverableObject = $DiscoverableActor<ClusterSystem>
