import DistributedCluster
import DurableWorkflows
import TurgaiDomain
import TurgaiTimers
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Something kept due in a space, as its tasks show it: a chat's reminder, or an object's field,
/// with when it's due.
public struct KeptTask: Codable, Sendable, Equatable, Identifiable {
    /// The durable schedule or timer that keeps it.
    public typealias ID = TimerID

    /// What it's for: a chat's reminder, by its name there, doing what `does` says; or an
    /// object's field.
    public enum Of: Codable, Sendable, Equatable {
        case chat(ConversationID, name: String, does: String)
        case object(ObjectIdentity, field: String)
    }

    public let id: ID
    public let of: Of
    public let due: When
    public let paused: Bool

    public init(id: ID, of: Of, due: When, paused: Bool) {
        self.id = id
        self.of = of
        self.due = due
        self.paused = paused
    }
}

/// What whoever follows a space's tasks is told as they change.
public enum TasksNotice: Codable, Sendable, Equatable {
    /// It's kept due as it says now: new, or changed.
    case kept(KeptTask)
    /// It isn't due any more.
    case ended(KeptTask.ID)
}

/// A space's tasks as they change, as Hail's agent gives its activity: each follower subscribes,
/// and pulls what's told it. It holds no one who follows, and nothing durable, since the tasks are
/// their workflows'; it's gone once no one follows them.
@VirtualActor
public distributed actor SpaceTasks {
    public typealias ActorSystem = ClusterSystem
    public typealias Dependency = SpaceID

    private var pulls = Pulls<TasksNotice>()

    public init(actorSystem: ActorSystem, dependency: SpaceID) async throws {
        self.actorSystem = actorSystem
    }

    /// `space`'s tasks, as they change.
    public static func identified(by space: SpaceID, on actorSystem: ClusterSystem) async throws -> SpaceTasks {
        try await actorSystem.virtualActors.getActor(
            identifiedBy: .owned(by: space, "tasks", "kept"), dependency: space)
    }

    /// Its changes from now on, subscribed already: what's read of the tasks after this misses
    /// nothing.
    public nonisolated func subscription() async throws -> Subscription<TasksNotice> {
        let subscriber = UUID()
        try await subscribe(subscriber)
        return Subscription(subscriber, pull: { try await self.next(for: $0) }, leave: { try await self.leave($0) })
    }

    distributed func subscribe(_ subscriber: UUID) {
        pulls.subscribe(subscriber)
    }

    /// `subscriber`'s next change: from its backlog, or the next one told. `nil` once it's left.
    distributed func next(for subscriber: UUID) async -> TasksNotice? {
        switch pulls.take(subscriber) {
        case .element(let notice): return notice
        case .ended: return nil
        case .empty: return await withCheckedContinuation { pulls.park(subscriber, $0) }
        }
    }

    distributed func leave(_ subscriber: UUID) {
        pulls.leave(subscriber)
    }

    /// `notice` told to each subscriber.
    public distributed func told(_ notice: TasksNotice) {
        pulls.tell(notice)
    }

    /// Gone once no one follows the space's tasks.
    public func shouldDeactivate() async -> Bool {
        pulls.isEmpty
    }
}

extension ClusterSystem {
    /// Tells whoever follows `space`'s tasks `notice`.
    public func tellTasks(in space: SpaceID, _ notice: TasksNotice) async {
        do {
            try await SpaceTasks.identified(by: space, on: self).told(notice)
        } catch {
            log.warning("A space's tasks couldn't be told a change", metadata: ["error": "\(error)"])
        }
    }
}
