import DistributedCluster
import DurableWorkflows
import NorbyDomain
import Synchronization

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The narrowed slice of the node's actor system that tools and effects may
/// use.
///
/// Only the workflow and virtual-actor verbs Norby actually needs are
/// reachable, and tests can substitute fakes without a node.
///
/// The access discipline follows swift-dependencies:
///
/// - The production facade is registered exactly once at the application
///   boundary with ``prepare(_:)``.
/// - Production code reads ``current`` ambiently and never wraps calls.
/// - ``withActorSystemDependency(_:operation:)`` exists only to override
///   behavior — in tests or deliberately scoped experiments.
///
/// The ambient read is what lets inert effect values (which cannot carry a
/// live client and whose `run` takes no parameters) reach the system. It is
/// process-wide and node-local: durable work firing later, possibly after a
/// restart, runs in a fresh process and must keep using its own
/// `context.system`, never this facade.
public struct ActorSystemDependency: Sendable {
    public var workflows: WorkflowActions
    public var virtualActors: VirtualActorActions

    public init(workflows: WorkflowActions, virtualActors: VirtualActorActions) {
        self.workflows = workflows
        self.virtualActors = virtualActors
    }

    /// The facade over a live node.
    public static func live(on actorSystem: ClusterSystem) -> ActorSystemDependency {
        ActorSystemDependency(
            workflows: WorkflowActions(
                startTimer: { id, input, retryPolicy in
                    try await actorSystem.workflows.start(
                        type: TimerWorkflow.self,
                        options: WorkflowOptions(id: id, retryPolicy: retryPolicy),
                        input: input
                    )
                },
                cancelTimer: { id in
                    try await actorSystem.workflows.cancel(
                        type: TimerWorkflow.self,
                        options: WorkflowOptions(id: id)
                    )
                },
                listTimers: {
                    try await actorSystem.workflows.listWorkflows(workflow: TimerWorkflow.self)
                },
                schedule: { id, recurrence, request, retryPolicy, overlapPolicy in
                    try await actorSystem.workflows.schedule(
                        id: id,
                        recurrence: recurrence,
                        workflow: ScheduleWorkflow.self,
                        input: request,
                        retryPolicy: retryPolicy,
                        overlapPolicy: overlapPolicy
                    )
                },
                cancelSchedule: { id in
                    try await actorSystem.workflows.cancelSchedule(
                        id: id,
                        workflow: ScheduleWorkflow.self
                    )
                },
                triggerSchedule: { id in
                    try await actorSystem.workflows.triggerSchedule(
                        id: id,
                        workflow: ScheduleWorkflow.self
                    )
                },
                listSchedules: {
                    try await actorSystem.workflows.listSchedules(workflow: ScheduleWorkflow.self)
                }
            ),
            virtualActors: VirtualActorActions(
                resolveUser: { userID in
                    try await User.resolve(on: actorSystem, userID: userID)
                }
            )
        )
    }
}

/// The durable-workflow verbs, already bound to Norby's workflow types.
public struct WorkflowActions: Sendable {
    public var startTimer: @Sendable (WorkflowID, Timer.Input, RetryPolicy?) async throws -> Void
    public var cancelTimer: @Sendable (WorkflowID) async throws -> Void
    public var listTimers: @Sendable () async throws -> [WorkflowDescription]
    public var schedule:
        @Sendable (
            ScheduleID, Calendar.RecurrenceRule, Schedule.Request, RetryPolicy?,
            ScheduleOverlapPolicy
        ) async throws -> Void
    public var cancelSchedule: @Sendable (ScheduleID) async throws -> Void
    public var triggerSchedule: @Sendable (ScheduleID) async throws -> ScheduleTriggerOutcome
    public var listSchedules: @Sendable () async throws -> [ScheduleDescription]

    public init(
        startTimer: @escaping @Sendable (WorkflowID, Timer.Input, RetryPolicy?) async throws -> Void,
        cancelTimer: @escaping @Sendable (WorkflowID) async throws -> Void,
        listTimers: @escaping @Sendable () async throws -> [WorkflowDescription],
        schedule:
            @escaping @Sendable (
                ScheduleID, Calendar.RecurrenceRule, Schedule.Request, RetryPolicy?,
                ScheduleOverlapPolicy
            ) async throws -> Void,
        cancelSchedule: @escaping @Sendable (ScheduleID) async throws -> Void,
        triggerSchedule: @escaping @Sendable (ScheduleID) async throws -> ScheduleTriggerOutcome,
        listSchedules: @escaping @Sendable () async throws -> [ScheduleDescription]
    ) {
        self.startTimer = startTimer
        self.cancelTimer = cancelTimer
        self.listTimers = listTimers
        self.schedule = schedule
        self.cancelSchedule = cancelSchedule
        self.triggerSchedule = triggerSchedule
        self.listSchedules = listSchedules
    }
}

/// Typed virtual-actor resolution. Deliberately not a generic `resolve`:
/// only the actors Norby's tools actually address are exposed.
public struct VirtualActorActions: Sendable {
    public var resolveUser: @Sendable (NorbyDomain.UserID) async throws -> User

    public init(resolveUser: @escaping @Sendable (NorbyDomain.UserID) async throws -> User) {
        self.resolveUser = resolveUser
    }
}

private enum ActorSystemDependencyStorage {
    /// Task-local override, set only by ``withActorSystemDependency(_:operation:)``.
    @TaskLocal
    static var override: ActorSystemDependency?

    /// The production facade, registered once via ``ActorSystemDependency/prepare(_:)``.
    static let prepared = Mutex<ActorSystemDependency?>(nil)
}

extension ActorSystemDependency {
    /// Registers the production facade. Called exactly once at the
    /// application boundary, before any tool or effect runs.
    public static func prepare(_ dependency: ActorSystemDependency) {
        ActorSystemDependencyStorage.prepared.withLock { prepared in
            precondition(
                prepared == nil,
                "ActorSystemDependency.prepare must run exactly once, at the application boundary."
            )
            prepared = dependency
        }
    }

    /// The facade for the current context: the task-local override when one
    /// is installed, otherwise the registered production facade.
    public static var current: ActorSystemDependency {
        if let override = ActorSystemDependencyStorage.override {
            return override
        }
        guard let prepared = ActorSystemDependencyStorage.prepared.withLock({ $0 }) else {
            preconditionFailure(
                "ActorSystemDependency was read before prepare(_:) ran at the application boundary."
            )
        }
        return prepared
    }
}

/// Overrides the actor-system facade for one operation. This exists to
/// change behavior — tests and deliberately scoped experiments. Production
/// code registers once with ``ActorSystemDependency/prepare(_:)`` and reads
/// ``ActorSystemDependency/current`` ambiently.
public func withActorSystemDependency<Result>(
    _ dependency: ActorSystemDependency,
    operation: () async throws -> Result
) async rethrows -> Result {
    try await ActorSystemDependencyStorage.$override.withValue(dependency) {
        try await operation()
    }
}
