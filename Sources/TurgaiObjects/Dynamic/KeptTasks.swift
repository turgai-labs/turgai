import DistributedCluster
import DurableWorkflows
import TurgaiDomain

/// Something kept due in a space, as its tasks show it: a chat's reminder, or an object's field,
/// with when it's due.
public struct KeptTask: Codable, Sendable, Equatable, Identifiable {
    /// The durable schedule or timer that keeps it.
    public enum ID: Hashable, Codable, Sendable {
        case schedule(ScheduleID)
        case timer(WorkflowID)
    }

    /// What it's for: a chat's reminder, by its name there, doing what `does` says; or an
    /// object's field.
    public enum Of: Codable, Sendable, Equatable {
        case chat(ConversationID, name: String, does: String)
        case object(ObjectIdentity, field: String)
    }

    public let id: ID
    public let of: Of
    public let due: ObjectDue
    public let paused: Bool
    /// Who made it: who may change it, besides the space's admins.
    public let maker: UserID

    public init(id: ID, of: Of, due: ObjectDue, paused: Bool, maker: UserID) {
        self.id = id
        self.of = of
        self.due = due
        self.paused = paused
        self.maker = maker
    }
}

/// What whoever follows a space's tasks is told as they change.
public enum TasksNotice: Codable, Sendable, Equatable {
    /// It's kept due as it says now: new, or changed.
    case kept(KeptTask)
    /// It isn't due any more.
    case ended(KeptTask.ID)
}

/// Where a connection following a space's tasks is told what changes there: checked in under the
/// space's key while it lives, which is for as long as the connection follows them.
public distributed actor TasksListener {
    public typealias ActorSystem = ClusterSystem

    private let onNotice: @Sendable (TasksNotice) async -> Void

    public init(
        actorSystem: ClusterSystem, following space: SpaceID,
        onNotice: @escaping @Sendable (TasksNotice) async -> Void
    ) async {
        self.actorSystem = actorSystem
        self.onNotice = onNotice
        await actorSystem.receptionist.checkIn(self, with: .tasks(in: space))
    }

    public distributed func told(_ notice: TasksNotice) async {
        await onNotice(notice)
    }
}

extension DistributedReception.Key where Guest == TasksListener {
    /// Whoever follows `space`'s tasks.
    static func tasks(in space: SpaceID) -> Self {
        Self(id: "tasks-\(space.rawValue.uuidString)")
    }
}

extension ClusterSystem {
    /// Tells whoever follows `space`'s tasks `notice`.
    public func tellTasks(in space: SpaceID, _ notice: TasksNotice) async {
        for listener in await receptionist.lookup(.tasks(in: space)) {
            try? await listener.told(notice)
        }
    }
}
