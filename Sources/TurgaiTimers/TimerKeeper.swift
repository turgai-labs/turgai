import AttributedCalls
import Crypto
import Distributed
import DistributedCluster
import DurableWorkflows
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Whoever sets something due: told each time it's due, as the one it set it as. It's a virtual
/// actor, which a due thing reaches wherever and whenever it runs then.
@Resolvable
public protocol TimerOwner: DistributedActor where ActorSystem == ClusterSystem {
    /// `firing` is due now, as the run `run` of it: the same run each time it's retried.
    distributed func timerFired(_ firing: Firing, run: WorkflowID) async throws
}

/// Something due, kept durably: by which id, whose it is, the name it was set by, what makes it
/// due, and what its owner said about it, which only its owner reads.
public struct Firing: Codable, Sendable, Equatable {
    public let id: TimerID
    /// Whose it is: told when it's due, as its own work.
    public let owner: VirtualActorID
    /// How its owner is reached, as the cluster keeps a reference.
    let reached: StoredReference
    public let name: String
    public let due: When
    /// What its owner said about it as it set it.
    public let about: Data

    /// What its owner said about it, read as `type`: none when it isn't one.
    public func about<About: Decodable>(as type: About.Type) -> About? {
        try? JSONDecoder().decode(type, from: about)
    }
}

/// A durable timer's or schedule's id.
public enum TimerID: Hashable, Codable, Sendable {
    case schedule(ScheduleID)
    case timer(WorkflowID)
}

/// Something due as it is now: when it's next due, and whether it's paused.
public struct Kept: Sendable, Equatable {
    public let firing: Firing
    public let next: Date?
    public let paused: Bool
}

/// Why something can't be set due.
public enum TimerRefusal: Error, Sendable, Equatable {
    /// Whoever set it isn't a virtual actor, which nothing reaches after it restarts.
    case notVirtual
}

/// A reference to an actor as the cluster keeps it: read back with the cluster, it reaches the
/// actor again, a virtual one wherever and whenever it runs.
struct StoredReference: Codable, Sendable, Equatable {
    /// Which serializer wrote it, and what type it says it holds: its manifest's parts.
    let serializer: UInt32
    let hint: String?
    let bytes: Data

    init(_ id: ClusterSystem.ActorID, on system: ClusterSystem) throws {
        let serialized = try system.serialization.serialize(id)
        serializer = serialized.manifest.serializerID.value
        hint = serialized.manifest.hint
        bytes = serialized.buffer.readData()
    }

    func id(on system: ClusterSystem) throws -> ClusterSystem.ActorID {
        let manifest = Serialization.Manifest(
            serializerID: Serialization.SerializerID(integerLiteral: serializer), hint: hint)
        return try system.serialization.deserialize(
            as: ClusterSystem.ActorID.self, from: .data(bytes), using: manifest)
    }
}

/// What's due, set, changed and read for whoever sets it: each kept by its durable workflow, which
/// tells its owner when it's due.
public struct TimerKeeper: Sendable {
    private let system: ClusterSystem

    public init(on system: ClusterSystem) {
        self.system = system
    }

    /// A delivery an outage interrupts isn't lost: the workflow retries telling the owner, and
    /// the durable runtime keeps the policy for each time it's due.
    public static let retryPolicy = RetryPolicy(
        initialInterval: .seconds(5),
        backoffCoefficient: 2,
        maximumInterval: .seconds(300),
        maximumAttempts: 6
    )

    // MARK: Timers

    /// The timer `name` of `owner` set for `date`, in place of any other of that name: due once
    /// then. `about` is what `owner` is told with it.
    @discardableResult
    public func set<About: Encodable>(
        _ name: String, at timer: Timer, of owner: some TimerOwner, about: About
    ) async throws -> TimerID {
        let virtual = try Self.virtual(owner)
        for now in try await timers(of: virtual) where now.firing.name == name {
            try await cancel(now.firing.id)
        }
        let id = WorkflowID(rawValue: "turgai-timer-" + Self.uuid(virtual.rawValue, name, "\(timer.date.timeIntervalSince1970)"))
        let firing = Firing(
            id: .timer(id), owner: virtual, reached: try StoredReference(owner.id, on: system), name: name,
            due: .timer(timer), about: try JSONEncoder().encode(about))
        try await system.workflows.start(
            type: TimerWorkflow.self, options: WorkflowOptions(id: id, retryPolicy: Self.retryPolicy), input: firing)
        return firing.id
    }

    // MARK: Schedules

    /// The schedule `name` of `owner` set as `schedule` says, in place of the one of that name.
    /// `about` is what `owner` is told with it each time.
    @discardableResult
    public func set<About: Encodable>(
        _ name: String, every schedule: Schedule, of owner: some TimerOwner, about: About
    ) async throws -> TimerID {
        let rule = try schedule.rule()
        let virtual = try Self.virtual(owner)
        let id = ScheduleID(rawValue: "turgai-schedule-" + Self.uuid(virtual.rawValue, name))
        let workflows = system.workflows
        if try await workflows.describeSchedule(id: id, workflow: ScheduleWorkflow.self) != nil {
            try await workflows.cancelSchedule(id: id, workflow: ScheduleWorkflow.self)
        }
        let firing = Firing(
            id: .schedule(id), owner: virtual, reached: try StoredReference(owner.id, on: system), name: name,
            due: .schedule(schedule), about: try JSONEncoder().encode(about))
        try await workflows.schedule(
            id: id, recurrence: rule, workflow: ScheduleWorkflow.self, input: firing,
            retryPolicy: Self.retryPolicy, overlapPolicy: .skip)
        return firing.id
    }

    /// The schedule `id` paused, or due again as it says: as it is after.
    public func pause(_ id: ScheduleID, _ paused: Bool) async throws -> Kept? {
        let workflows = system.workflows
        if paused {
            try await workflows.pauseSchedule(id: id, workflow: ScheduleWorkflow.self, reason: nil)
        } else {
            try await workflows.unpauseSchedule(id: id, workflow: ScheduleWorkflow.self, reason: nil)
        }
        return try await now(id)
    }

    // MARK: Both

    /// What `owner` set as `name`, a timer or a schedule, no longer due: what was.
    @discardableResult
    public func cancel(_ name: String, of owner: some TimerOwner) async throws -> [TimerID] {
        let virtual = try Self.virtual(owner)
        var ended: [TimerID] = []
        for now in try await schedules(of: virtual) + timers(of: virtual) where now.firing.name == name {
            try await cancel(now.firing.id)
            ended.append(now.firing.id)
        }
        return ended
    }

    /// `id` no longer due.
    public func cancel(_ id: TimerID) async throws {
        switch id {
        case .schedule(let id):
            try await system.workflows.cancelSchedule(id: id, workflow: ScheduleWorkflow.self)
        case .timer(let id):
            try await system.workflows.cancel(type: TimerWorkflow.self, options: WorkflowOptions(id: id))
        }
    }

    /// The schedule `id` as it is now, while it's due.
    public func now(_ id: ScheduleID) async throws -> Kept? {
        guard let description = try await system.workflows.describeSchedule(id: id, workflow: ScheduleWorkflow.self),
            let firing = try? JSONDecoder().decode(Firing.self, from: description.inputData)
        else { return nil }
        return Kept(firing: firing, next: description.nextFireAt, paused: description.paused)
    }

    /// Every schedule that's due, or `owner`'s only.
    public func schedules(of owner: VirtualActorID? = nil) async throws -> [Kept] {
        let decoder = JSONDecoder()
        return try await system.workflows.listSchedules(workflow: ScheduleWorkflow.self).compactMap { description in
            guard let firing = try? decoder.decode(Firing.self, from: description.inputData),
                owner == nil || firing.owner == owner
            else { return nil }
            return Kept(firing: firing, next: description.nextFireAt, paused: description.paused)
        }
    }

    /// Every timer that isn't due yet, or `owner`'s only.
    public func timers(of owner: VirtualActorID? = nil) async throws -> [Kept] {
        let decoder = JSONDecoder()
        return try await system.workflows.listWorkflows(workflow: TimerWorkflow.self).compactMap { description in
            guard case .running = description.status, let data = description.inputData,
                let firing = try? decoder.decode(Firing.self, from: data), owner == nil || firing.owner == owner,
                case .timer(let timer) = firing.due
            else { return nil }
            return Kept(firing: firing, next: timer.date, paused: false)
        }
    }

    private static func virtual(_ owner: some TimerOwner) throws -> VirtualActorID {
        guard let virtual = owner.id.virtualActorID else { throw TimerRefusal.notVirtual }
        return virtual
    }

    /// The same id for the same parts, every time.
    private static func uuid(_ parts: String...) -> String {
        let digest = Array(SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8)).prefix(16))
        return UUID(
            uuid: (
                digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
            )
        ).uuidString
    }
}

/// A timer, kept durably: at its date, its owner is told, once.
@Workflow
public struct TimerWorkflow {
    public typealias Activities = FiringActivities
    public typealias Input = Firing
    public typealias Output = DurableVoid

    public init() {}

    public func run(input: Input, context: WorkflowContext) async throws -> Output {
        if case .timer(let timer) = input.due {
            try await context.sleep(until: timer.date, summary: "timer")
        }
        return try await context.executeActivity(FiringActivities.Activities.Fire.self, input: input)
    }
}

/// A schedule, kept durably: each time it's due, its owner is told.
@Workflow
public struct ScheduleWorkflow {
    public typealias Activities = FiringActivities
    public typealias Input = Firing
    public typealias Output = DurableVoid

    public init() {}

    public func run(input: Input, context: WorkflowContext) async throws -> Output {
        try await context.executeActivity(FiringActivities.Activities.Fire.self, input: input)
    }
}

@ActivityContainer
public struct FiringActivities {
    public init() {}

    /// Tells the owner it's due, as its own work: it reaches the owner as its own doing, starting
    /// from it.
    @Activity
    public func fire(input: Firing, context: ActivityContext) async throws -> DurableVoid {
        let owner = try $TimerOwner.resolve(id: try input.reached.id(on: context.system), using: context.system)
        try await Call.asWork(of: input.owner) {
            try await owner.timerFired(input, run: context.workflowID)
        }
        return DurableVoid()
    }
}
