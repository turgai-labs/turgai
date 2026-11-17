import DistributedCluster
import TurgaiDomain

extension DistributedReception.Key where Guest == DiscoverableObject {
    /// Where the virtual actors offered in `space` check in, found there by the name their id gives
    /// them: no other space finds them.
    public static func virtualObjects(in space: SpaceID) -> Self {
        Self(id: "turgai.objects.virtual/\(space.rawValue.uuidString)")
    }
}
