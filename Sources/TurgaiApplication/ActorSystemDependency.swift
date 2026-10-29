import DistributedCluster
import DurableWorkflows
import Hail
import Synchronization
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The narrowed slice of the node's actor system that tools and effects may
/// use.
///
/// Only the workflow and virtual-actor verbs Turgai actually needs are
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
///
/// The narrowed slice of the node's actor system exposed to effect-backed
/// tools. Application actors must use their explicit `actorSystem` property.
/// This facade is intentionally not a general actor-system dependency; it
/// exists only at the tool/effect boundary.
///
/// `Effect` is a ceremonial ownership label. It does not alter the stored
/// capabilities or runtime behavior; it makes a tool call visibly name the
/// effect whose execution needs those capabilities. Keep this dependency in
/// tools and effects, not in application actors.
public struct ActorSystemDependency<Effect: ScopedEffect>: Sendable {
    public var workflows: WorkflowActions
    public var virtualActors: VirtualActorActions

    public init(workflows: WorkflowActions, virtualActors: VirtualActorActions) {
        self.workflows = workflows
        self.virtualActors = virtualActors
    }

    /// The facade over a live node.
    public static func live(on actorSystem: ClusterSystem) -> ActorSystemDependency<Effect> {
        ActorSystemDependency<Effect>(
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
                pauseSchedule: { id, reason in
                    try await actorSystem.workflows.pauseSchedule(
                        id: id,
                        workflow: ScheduleWorkflow.self,
                        reason: reason
                    )
                },
                unpauseSchedule: { id, reason in
                    try await actorSystem.workflows.unpauseSchedule(
                        id: id,
                        workflow: ScheduleWorkflow.self,
                        reason: reason
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
                },
                notify: { conversationID, text in
                    try await actorSystem.turgaiChannelRuntime.dependencies().connections
                        .conversation(conversationID).notify(text)
                }
            )
        )
    }
}

/// The durable-workflow verbs, already bound to Turgai's workflow types.
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
    public var pauseSchedule: @Sendable (ScheduleID, String?) async throws -> Void
    public var unpauseSchedule: @Sendable (ScheduleID, String?) async throws -> Void
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
        pauseSchedule: @escaping @Sendable (ScheduleID, String?) async throws -> Void = { _, _ in },
        unpauseSchedule: @escaping @Sendable (ScheduleID, String?) async throws -> Void = { _, _ in },
        triggerSchedule: @escaping @Sendable (ScheduleID) async throws -> ScheduleTriggerOutcome,
        listSchedules: @escaping @Sendable () async throws -> [ScheduleDescription]
    ) {
        self.startTimer = startTimer
        self.cancelTimer = cancelTimer
        self.listTimers = listTimers
        self.schedule = schedule
        self.cancelSchedule = cancelSchedule
        self.pauseSchedule = pauseSchedule
        self.unpauseSchedule = unpauseSchedule
        self.triggerSchedule = triggerSchedule
        self.listSchedules = listSchedules
    }
}

/// Typed virtual-actor resolution. Deliberately not a generic `resolve`:
/// only the actors Turgai's tools actually address are exposed.
public struct VirtualActorActions: Sendable {
    public var resolveUser: @Sendable (TurgaiDomain.UserID) async throws -> User
    /// Says text in a conversation, as its connections deliver what it says.
    public var notify: @Sendable (ConversationID, String) async throws -> Void

    public init(
        resolveUser: @escaping @Sendable (TurgaiDomain.UserID) async throws -> User,
        notify: @escaping @Sendable (ConversationID, String) async throws -> Void
    ) {
        self.resolveUser = resolveUser
        self.notify = notify
    }
}

private enum ActorSystemDependencyStorage {
    struct Values: Sendable {
        let workflows: WorkflowActions
        let virtualActors: VirtualActorActions
    }

    /// Task-local override, set only by ``withActorSystemDependency(_:operation:)``.
    @TaskLocal
    static var override: Values?

    /// The production facade, registered once via ``ActorSystemDependency/prepare(_:)``.
    static let prepared = Mutex<Values?>(nil)
}

extension ActorSystemDependency {
    /// Registers the production facade. Called exactly once at the
    /// application boundary, before any tool or effect runs.
    public static func prepare(_ dependency: ActorSystemDependency<Effect>) {
        ActorSystemDependencyStorage.prepared.withLock { prepared in
            precondition(
                prepared == nil,
                "ActorSystemDependency.prepare must run exactly once, at the application boundary."
            )
            prepared = ActorSystemDependencyStorage.Values(
                workflows: dependency.workflows,
                virtualActors: dependency.virtualActors
            )
        }
    }

    /// The facade for the current context: the task-local override when one
    /// is installed, otherwise the registered production facade.
    public static var current: ActorSystemDependency<Effect> {
        if let override = ActorSystemDependencyStorage.override {
            return ActorSystemDependency(
                workflows: override.workflows,
                virtualActors: override.virtualActors
            )
        }
        guard let prepared = ActorSystemDependencyStorage.prepared.withLock({ $0 }) else {
            preconditionFailure(
                "ActorSystemDependency was read before prepare(_:) ran at the application boundary."
            )
        }
        return ActorSystemDependency(
            workflows: prepared.workflows,
            virtualActors: prepared.virtualActors
        )
    }
}

/// Overrides the actor-system facade for one operation. This exists to
/// change behavior — tests and deliberately scoped experiments. Production
/// code registers once with ``ActorSystemDependency/prepare(_:)`` and reads
/// ``ActorSystemDependency/current`` ambiently.
public func withActorSystemDependency<Effect: ScopedEffect, Result>(
    _ dependency: ActorSystemDependency<Effect>,
    operation: () async throws -> Result
) async rethrows -> Result {
    let values = ActorSystemDependencyStorage.Values(
        workflows: dependency.workflows,
        virtualActors: dependency.virtualActors
    )
    return try await ActorSystemDependencyStorage.$override.withValue(values) {
        try await operation()
    }
}
