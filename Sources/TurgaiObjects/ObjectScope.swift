import DiscoverableActors
import Distributed
import DistributedCluster
import TurgaiDomain

/// Any discoverable object, held without knowing its Swift type.
public typealias DiscoverableObject = $DiscoverableActor<ClusterSystem>

/// Who can see an object checked in with the cluster receptionist.
///
/// Only objects a model starts from check in: one reachable through their actions
/// is found by walking to it. Visibility only decides what a model can find; what
/// it may do with an object it holds is still decided by the authority at invocation.
public enum ObjectScope: Hashable, Codable, Sendable {
    /// Belongs to the machine, such as the Mac itself or the user's reminders.
    case shared
    /// Belongs to one person, such as an object their model built.
    case owned(by: UserID)
}

extension ObjectScope {
    /// What a person sees: the machine's objects and their own.
    public static func visible(to user: UserID) -> [ObjectScope] {
        [.shared, .owned(by: user)]
    }

    /// The cluster receptionist key for this visibility scope.
    public var receptionistKey: DistributedReception.Key<DiscoverableObject> {
        switch self {
        case .shared:
            .init(id: "turgai.objects.shared")
        case .owned(let user):
            .init(id: "turgai.objects.owned.\(user.rawValue)")
        }
    }
}
