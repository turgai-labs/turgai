import DiscoverableActors
import DistributedCluster
import DurableWorkflows
import TurgaiCalls
import TurgaiDomain
import TurgaiObjects
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A chat's schedule, as it's listed: its name, when it's due, what it does then, when it's next
/// due, and whether it's paused.
@Describable
public struct ScheduleInChat: Codable, Sendable, Equatable {
    public let name: String
    public let schedule: TurgaiObjects.Schedule
    public let then: WhenDue
    public let next: Date?
    public let paused: Bool
}

/// An object's schedule in a chat, as it's listed: the object, its property that holds it, when
/// it's due, and when it's next due. Its object's code changes or ends it.
@Describable
public struct ObjectScheduleInChat: Codable, Sendable, Equatable {
    public let object: String
    public let property: String
    public let schedule: TurgaiObjects.Schedule
    public let next: Date?
    public let paused: Bool
}

/// What's scheduled in a chat: its own schedules, and its objects'.
@Describable
public struct SchedulesInChat: Codable, Sendable, Equatable {
    public let chat: [ScheduleInChat]
    public let objects: [ObjectScheduleInChat]
}

/// Why a chat's schedule or timer can't be made or changed as asked.
public enum DueInChatError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    case inNoChat
    case unnamed
    /// The chat has no `kind` named so: with the names of those it has.
    case none(kind: String, String, named: [String])
    case notTheirs(String)
    case past(Date)
    case noMinutes(Int)

    public var description: String {
        switch self {
        case .inNoChat: "this happens in no chat"
        case .unnamed: "it has a name"
        case .none(let kind, let name, let names):
            "this chat has no \(kind) `\(name)`"
                + (names.isEmpty ? "" : "; its \(kind)s: " + names.map { "`\($0)`" }.joined(separator: ", "))
        case .notTheirs(let name): "`\(name)` is changed by whoever made it, or the chat's admins"
        case .past(let date): "\(date.formatted(date: .abbreviated, time: .shortened)) has passed"
        case .noMinutes(let minutes): "`minutes: \(minutes)` is at least 1"
        }
    }

    /// The call's chain, and the chat it happens in.
    static func chat() throws -> (CallChain, ConversationID) {
        guard let chain = CallChain.current, let chat = chain.place else { throw DueInChatError.inNoChat }
        return (chain, chat)
    }

    /// Whether `chain`'s person may change what `owner` made: whoever made it, or an admin of the
    /// chat's space.
    static func mayChange(madeBy owner: UserID, _ chain: CallChain) -> Bool {
        owner == chain.scope.person || chain.scope.permissions.tasks == .manage
    }
}

/// The chats' schedules: each due as it says, by the name it's given in its chat, saying text
/// there or asking the chat's agent each time. What an object's own schedules are, it lists.
@Discoverable
@VirtualActor
public distributed actor Scheduler {
    public typealias ActorSystem = ClusterSystem
    public typealias Dependency = SpaceID

    public static let kind = BuiltInKind(rawValue: "Scheduler")

    /// The space whose it is.
    private let space: SpaceID

    /// `space`'s scheduler, wherever and whenever it runs.
    public static func of(_ space: SpaceID, on actorSystem: ClusterSystem) async throws -> Scheduler {
        try await actorSystem.virtualActors.getActor(
            identifiedBy: VirtualActorID(rawValue: "builtin/\(space.rawValue.uuidString)/scheduler"), dependency: space)
    }

    public init(actorSystem: ActorSystem, dependency space: SpaceID) async throws {
        self.actorSystem = actorSystem
        self.space = space
    }

    /// Makes the schedule `name` in this chat, or makes it again: due as `schedule` says, doing
    /// `then` each time.
    /// - Parameters:
    ///   - name: The schedule's name in this chat.
    ///   - schedule: When it's due.
    ///   - then: What it does each time it's due.
    @DiscoverableAction
    public distributed func every(name: String, schedule: TurgaiObjects.Schedule, then: WhenDue) async throws
        -> ScheduleInChat
    {
        let (chain, chat) = try DueInChatError.chat()
        let name = ObjectNames.handle(for: name)
        guard !name.trimmed().isEmpty else { throw DueInChatError.unnamed }
        let rule = try schedule.rule()
        let id = ChatSchedule.id(in: chat, of: chain.scope.space, named: name)
        let workflows = actorSystem.workflows
        if let made = try await made(id) {
            guard DueInChatError.mayChange(madeBy: made.ownerID, chain) else { throw DueInChatError.notTheirs(name) }
            try await workflows.cancelSchedule(id: id, workflow: ScheduleWorkflow.self)
        }
        let entry = ChatSchedule(
            name: name, schedule: schedule, then: then, ownerID: chain.scope.person, in: chain.scope.space,
            conversationID: chat)
        try await workflows.schedule(
            id: id, recurrence: rule, workflow: ScheduleWorkflow.self, input: entry,
            retryPolicy: ChatSchedule.retryPolicy, overlapPolicy: .skip)
        await actorSystem.tellTasks(in: chain.scope.space, .kept(KeptTask(entry, id: id, paused: false)))
        let next = try await workflows.describeSchedule(id: id, workflow: ScheduleWorkflow.self)?.nextFireAt
        return ScheduleInChat(name: name, schedule: schedule, then: then, next: next, paused: false)
    }

    /// What's scheduled in this chat: its schedules, and its objects'.
    @DiscoverableAction(safe: true, idempotent: true)
    public distributed func list() async throws -> SchedulesInChat {
        let (chain, chat) = try DueInChatError.chat()
        let workflows = actorSystem.workflows
        let decoder = JSONDecoder()
        let schedules = try await workflows.listSchedules(workflow: ScheduleWorkflow.self).compactMap {
            description -> ScheduleInChat? in
            guard let entry = try? decoder.decode(ChatSchedule.self, from: description.inputData),
                entry.space == chain.scope.space, entry.conversationID == chat
            else { return nil }
            return ScheduleInChat(
                name: entry.name, schedule: entry.schedule, then: entry.then, next: description.nextFireAt,
                paused: description.paused)
        }
        let objects = try await workflows.listSchedules(workflow: ObjectScheduleWorkflow.self).compactMap {
            description -> ObjectScheduleInChat? in
            guard let firing = try? decoder.decode(ObjectFiring.self, from: description.inputData),
                firing.place == chat, case .schedule(let schedule) = firing.due
            else { return nil }
            return ObjectScheduleInChat(
                object: firing.object.rawValue, property: firing.property, schedule: schedule,
                next: description.nextFireAt, paused: description.paused)
        }
        return SchedulesInChat(
            chat: schedules.sorted { $0.name < $1.name },
            objects: objects.sorted { ($0.object, $0.property) < ($1.object, $1.property) })
    }

    /// Pauses this chat's schedule `name`: it isn't due until it's resumed.
    /// - Parameter name: The schedule's name in this chat.
    @DiscoverableAction
    public distributed func pause(name: String) async throws -> ScheduleInChat {
        try await changing(name) { id, workflows in
            try await workflows.pauseSchedule(id: id, workflow: ScheduleWorkflow.self, reason: nil)
        }
    }

    /// Resumes this chat's paused schedule `name`.
    /// - Parameter name: The schedule's name in this chat.
    @DiscoverableAction
    public distributed func resume(name: String) async throws -> ScheduleInChat {
        try await changing(name) { id, workflows in
            try await workflows.unpauseSchedule(id: id, workflow: ScheduleWorkflow.self, reason: nil)
        }
    }

    /// Ends this chat's schedule `name` for good.
    /// - Parameter name: The schedule's name in this chat.
    @DiscoverableAction
    public distributed func cancel(name: String) async throws -> ScheduleInChat {
        try await changing(name) { id, workflows in
            try await workflows.cancelSchedule(id: id, workflow: ScheduleWorkflow.self)
        }
    }

    /// Changes this chat's schedule `name` as `change` does, when it's theirs to change: what it
    /// is after.
    private func changing(
        _ written: String, _ change: (ScheduleID, DurableWorkflowsPlugin) async throws -> Void
    ) async throws -> ScheduleInChat {
        let (chain, chat) = try DueInChatError.chat()
        let name = ObjectNames.handle(for: written)
        let id = ChatSchedule.id(in: chat, of: chain.scope.space, named: name)
        guard let made = try await made(id) else {
            throw DueInChatError.none(kind: "schedule", written, named: try await list().chat.map(\.name))
        }
        guard DueInChatError.mayChange(madeBy: made.ownerID, chain) else { throw DueInChatError.notTheirs(name) }
        let workflows = actorSystem.workflows
        try await change(id, workflows)
        let after = try await workflows.describeSchedule(id: id, workflow: ScheduleWorkflow.self)
        await actorSystem.tellTasks(
            in: chain.scope.space,
            after.map { .kept(KeptTask(made, id: id, paused: $0.paused)) } ?? .ended(.schedule(id)))
        return ScheduleInChat(
            name: made.name, schedule: made.schedule, then: made.then, next: after?.nextFireAt,
            paused: after?.paused ?? false)
    }

    /// The schedule made as `id`, while there is one.
    private func made(_ id: ScheduleID) async throws -> ChatSchedule? {
        guard
            let description = try await actorSystem.workflows.describeSchedule(id: id, workflow: ScheduleWorkflow.self)
        else { return nil }
        return try? JSONDecoder().decode(ChatSchedule.self, from: description.inputData)
    }

}

/// Read by everyone: what each may change, it decides.
extension Scheduler: AccessControlled {
    /// Everyone in its space may use it, and no one from another.
    public distributed func access(for chain: CallChain) -> Access {
        chain.scope.space == space ? .readByEveryone : .nobody
    }
}
