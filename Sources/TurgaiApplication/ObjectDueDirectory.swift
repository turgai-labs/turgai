import Distributed
import DistributedCluster
import DurableWorkflows
import EventSourcing
import TurgaiDomain
import TurgaiObjects

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Something the runtime keeps due for an object: the property that's due, and when.
public struct ObjectDueListing: Equatable, Codable, Sendable {
    public let object: ObjectIdentity
    public let property: String
    public let due: ObjectDue

    public init(object: ObjectIdentity, property: String, due: ObjectDue) {
        self.object = object
        self.property = property
        self.due = due
    }
}

/// What one of the runtime's records of what's due for an object changes in the directory. Each
/// leaves the directory as it is when it's kept a second time.
public enum ObjectDueChange: Equatable, Sendable {
    /// The record `record` keeps `firing` due.
    case kept(PersistenceID, ObjectFiring)
    /// The record `record` keeps nothing due any more.
    case ended(PersistenceID)

    /// What `event`, the event of an object's schedule kept as `record`, changes: none for what
    /// the directory doesn't show.
    public init?(_ event: WorkflowSchedulerEvent, of record: PersistenceID) throws {
        switch event {
        case .scheduled(let scheduled):
            self = .kept(record, try JSONDecoder().decode(ObjectFiring.self, from: scheduled.inputData))
        case .cancelled:
            self = .ended(record)
        case .paused, .unpaused, .occurrenceClaimed, .occurrenceSkipped, .occurrenceTriggered, .occurrenceStarted,
            .occurrenceFinished:
            return nil
        }
    }

    /// What `event`, the event of an object's timer kept as `record`, changes: none for what the
    /// directory doesn't show.
    public init?(_ event: WorkflowEvent, of record: PersistenceID) throws {
        switch event {
        case .executionStarted(let input):
            self = .kept(record, try JSONDecoder().decode(ObjectFiring.self, from: input))
        case .executionCompleted, .executionCancelled, .executionFailed:
            self = .ended(record)
        case .activitySucceeded, .activityFailed, .timerScheduled, .timerFired, .timerCancelled, .timestampRecorded,
            .retryPolicyConfigured, .retryScheduled:
            return nil
        }
    }
}

/// Where a change to what's due in a space is told: one for each open connection that follows it.
public distributed actor ObjectDueListener {
    public typealias ActorSystem = ClusterSystem

    private let onChange: @Sendable () async -> Void

    public init(actorSystem: ClusterSystem, onChange: @escaping @Sendable () async -> Void) {
        self.actorSystem = actorSystem
        self.onChange = onChange
    }

    /// What's due in the space it follows changed.
    public distributed func changed() async {
        await onChange()
    }
}

/// The records the directory reads: the objects' schedules, and their timers.
private enum ObjectDueRecords {
    case schedules
    case timers
}

/// What the runtime keeps due for the objects of each space, read from the records of their
/// schedules and timers: one in the cluster, run where the journal can be read, as its projections
/// must be. It keeps nothing anywhere: each time it starts, it reads the records' events from the
/// beginning, then follows them.
public distributed actor ObjectDueDirectory: ClusterSingleton {
    public typealias ActorSystem = ClusterSystem

    /// What the cluster knows it by.
    public static let singletonName = "turgai-object-due-directory"

    /// The journal the records' events are read from: the concrete store, on this node.
    private let journal: any EventStore
    private let refreshInterval: Duration
    /// What's due for objects now, by the record keeping each.
    private var due: [PersistenceID: ObjectFiring] = [:]
    /// How far each kind of record's events are read.
    private var read: [ObjectDueRecords: Offset] = [:]
    /// Who's told as what's due in each space changes.
    private var followers: [SpaceID: Set<ObjectDueListener>] = [:]
    /// The projections, while it's the cluster's directory.
    private var following: [Task<Void, Never>] = []

    /// A directory read from the records' events in `journal`, read again every `refreshInterval`
    /// once it's caught up.
    public init(actorSystem: ClusterSystem, journal: any EventStore, refreshInterval: Duration = .seconds(1)) {
        self.actorSystem = actorSystem
        self.journal = journal
        self.refreshInterval = refreshInterval
    }

    /// What's due for the objects made in `space`, by object, then property.
    public distributed func dues(in space: SpaceID) -> [ObjectDueListing] {
        due.values.filter { $0.space == space }
            .sorted { ($0.object.rawValue, $0.property) < ($1.object.rawValue, $1.property) }
            .map { ObjectDueListing(object: $0.object, property: $0.property, due: $0.due) }
    }

    /// `listener` told as what's due in `space` changes, from now on.
    public distributed func follow(_ space: SpaceID, with listener: ObjectDueListener) {
        followers[space, default: []].insert(listener)
    }

    /// `listener` no longer told anything.
    public distributed func unfollow(_ listener: ObjectDueListener) {
        for space in followers.keys { followers[space]?.remove(listener) }
        followers = followers.filter { !$0.value.isEmpty }
    }

    /// `change`, read at `offset` among `records`' events, applied: then the followers of the space
    /// it changed are told, and one that can't be told is let go.
    private func apply(_ change: ObjectDueChange?, at offset: Offset, among records: ObjectDueRecords) async {
        read[records] = offset
        let changed: SpaceID?
        switch change {
        case .kept(let record, let firing)?:
            due[record] = firing
            changed = firing.space
        case .ended(let record)?:
            changed = due.removeValue(forKey: record)?.space
        case nil:
            changed = nil
        }
        guard let changed else { return }
        for listener in followers[changed] ?? [] {
            do {
                try await listener.changed()
            } catch {
                unfollow(listener)
            }
        }
    }

    /// Reads the objects' schedules' and timers' records from the beginning while it's the
    /// cluster's directory, then follows them; again from where it read whenever following fails.
    public func activateSingleton() async {
        due = [:]
        read = [:]
        let schedules = Projection<WorkflowSchedulerEvent>(tag: .schedules(of: ObjectScheduleWorkflow.self))
        let timers = Projection<WorkflowEvent>(tag: .workflows(of: ObjectTimerWorkflow.self))
        following = [
            Task {
                await schedules.runRestarting(
                    on: journal, refreshInterval: refreshInterval,
                    offset: { self.read[.schedules] ?? .start },
                    process: { envelope in
                        let change = try ObjectDueChange(envelope.event, of: envelope.persistenceID)
                        await self.apply(change, at: envelope.offset, among: .schedules)
                    },
                    failed: { self.failed($0) })
            },
            Task {
                await timers.runRestarting(
                    on: journal, refreshInterval: refreshInterval,
                    offset: { self.read[.timers] ?? .start },
                    process: { envelope in
                        let change = try ObjectDueChange(envelope.event, of: envelope.persistenceID)
                        await self.apply(change, at: envelope.offset, among: .timers)
                    },
                    failed: { self.failed($0) })
            },
        ]
    }

    /// Following the records failed with `error`: it starts again shortly.
    private func failed(_ error: any Error) {
        actorSystem.log.error(
            "The object due directory failed to follow the objects' schedules and timers; it starts again shortly",
            metadata: ["error": .string(String(describing: error))])
    }

    public func passivateSingleton() async {
        for projection in following { projection.cancel() }
        following = []
    }
}
