import DiscoverableActors
import DistributedCluster
import DurableWorkflows
import TurgaiCalls
import TurgaiDomain
import TurgaiObjects
import TurgaiTimers
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
    public let schedule: TurgaiTimers.Schedule
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
    public let schedule: TurgaiTimers.Schedule
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
    /// No person asked, for one that asks the chat's bot something: what's asked is a message.
    case noPersonAsked
    case unnamed
    /// The chat has no `kind` named so: with the names of those it has.
    case none(kind: String, String, named: [String])
    case past(Date)
    case noMinutes(Int)

    public var description: String {
        switch self {
        case .inNoChat: "this happens in no chat"
        case .noPersonAsked: "what asks the chat's bot is a person's, and no person asked"
        case .unnamed: "it has a name"
        case .none(let kind, let name, let names):
            "this chat has no \(kind) `\(name)`"
                + (names.isEmpty ? "" : "; its \(kind)s: " + names.map { "`\($0)`" }.joined(separator: ", "))
        case .past(let date): "\(date.formatted(date: .abbreviated, time: .shortened)) has passed"
        case .noMinutes(let minutes): "`minutes: \(minutes)` is at least 1"
        }
    }

    /// The call's chain, and the chat it happens in.
    static func chat() throws -> (CallChain, ConversationID) {
        guard let chain = CallChain.current, let chat = chain.place else { throw DueInChatError.inNoChat }
        return (chain, chat)
    }

    /// Refuses `then` when it asks the chat's bot something and no person asked: what's asked is
    /// a message, which only a person writes for now.
    static func askable(_ then: WhenDue, _ chain: CallChain) throws {
        if case .ask = then, chain.scope.person == nil { throw DueInChatError.noPersonAsked }
    }
}

/// The chats' schedules: each due as it says, by the name it's given in its chat, saying text
/// there or asking the chat's agent each time. It's told when one is due, as their owner. What an
/// object's own schedules are, it lists.
@Discoverable
@VirtualActor
public distributed actor Scheduler {
    public typealias ActorSystem = ClusterSystem
    public typealias Dependency = SpaceID

    /// The space whose it is.
    private let space: SpaceID

    /// `space`'s scheduler, wherever and whenever it runs.
    public static func of(_ space: SpaceID, on actorSystem: ClusterSystem) async throws -> Scheduler {
        try await actorSystem.virtualActors.getActor(identifiedBy: virtualID(of: space), dependency: space)
    }

    /// The id of `space`'s scheduler.
    static func virtualID(of space: SpaceID) -> VirtualActorID {
        .owned(by: space, "builtin", "scheduler")
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
    public distributed func every(name: String, schedule: TurgaiTimers.Schedule, then: WhenDue) async throws
        -> ScheduleInChat
    {
        let (chain, chat) = try DueInChatError.chat()
        let name = ObjectNames.handle(for: name)
        guard !name.trimmed().isEmpty else { throw DueInChatError.unnamed }
        try DueInChatError.askable(then, chain)
        let reminder = ChatReminder(
            name: name, then: then, askedBy: chain.scope.asker, in: chain.scope.space, conversationID: chat)
        let keeper = TimerKeeper(on: actorSystem)
        let id = try await keeper.set(
            ChatReminder.timerName(name, in: chat), every: schedule, of: try await Self.of(space, on: actorSystem),
            about: reminder)
        await actorSystem.tellTasks(
            in: chain.scope.space,
            .kept(KeptTask(id: id, of: .chat(chat, name: name, does: then.described), due: .schedule(schedule), paused: false)))
        let next = try await made(name, in: chat)?.next
        return ScheduleInChat(name: name, schedule: schedule, then: then, next: next, paused: false)
    }

    /// What's scheduled in this chat: its schedules, and its objects'.
    @DiscoverableAction(safe: true, idempotent: true)
    public distributed func list() async throws -> SchedulesInChat {
        let (chain, chat) = try DueInChatError.chat()
        let keeper = TimerKeeper(on: actorSystem)
        let schedules = try await keeper.schedules(of: Self.virtualID(of: space)).compactMap { now -> ScheduleInChat? in
            guard let reminder = now.firing.about(as: ChatReminder.self), reminder.conversationID == chat,
                case .schedule(let schedule) = now.firing.due
            else { return nil }
            return ScheduleInChat(
                name: reminder.name, schedule: schedule, then: reminder.then, next: now.next, paused: now.paused)
        }
        let objects = try await keeper.schedules().compactMap { now -> ObjectScheduleInChat? in
            guard let object = now.firing.about(as: ObjectTimerAbout.self), object.space == chain.scope.space,
                object.place == chat, case .schedule(let schedule) = now.firing.due
            else { return nil }
            return ObjectScheduleInChat(
                object: object.object.rawValue, property: now.firing.name, schedule: schedule, next: now.next,
                paused: now.paused)
        }
        return SchedulesInChat(
            chat: schedules.sorted { $0.name < $1.name },
            objects: objects.sorted { ($0.object, $0.property) < ($1.object, $1.property) })
    }

    /// Pauses this chat's schedule `name`: it isn't due until it's resumed.
    /// - Parameter name: The schedule's name in this chat.
    @DiscoverableAction
    public distributed func pause(name: String) async throws -> ScheduleInChat {
        try await changing(name) { id, keeper in _ = try await keeper.pause(id, true) }
    }

    /// Resumes this chat's paused schedule `name`.
    /// - Parameter name: The schedule's name in this chat.
    @DiscoverableAction
    public distributed func resume(name: String) async throws -> ScheduleInChat {
        try await changing(name) { id, keeper in _ = try await keeper.pause(id, false) }
    }

    /// Ends this chat's schedule `name` for good.
    /// - Parameter name: The schedule's name in this chat.
    @DiscoverableAction
    public distributed func cancel(name: String) async throws -> ScheduleInChat {
        try await changing(name) { id, keeper in try await keeper.cancel(.schedule(id)) }
    }

    /// Changes this chat's schedule `name` as `change` does, when it's theirs to change: what it
    /// is after.
    private func changing(_ written: String, _ change: (ScheduleID, TimerKeeper) async throws -> Void) async throws
        -> ScheduleInChat
    {
        let (chain, chat) = try DueInChatError.chat()
        let name = ObjectNames.handle(for: written)
        guard let made = try await made(name, in: chat), case .schedule(let id) = made.firing.id,
            case .schedule(let schedule) = made.firing.due, let reminder = made.firing.about(as: ChatReminder.self)
        else {
            throw DueInChatError.none(kind: "schedule", written, named: try await list().chat.map(\.name))
        }
        let keeper = TimerKeeper(on: actorSystem)
        try await change(id, keeper)
        let after = try await keeper.now(id)
        await actorSystem.tellTasks(
            in: chain.scope.space,
            after.flatMap { KeptTask($0, in: chain.scope.space) }.map { .kept($0) } ?? .ended(made.firing.id))
        return ScheduleInChat(
            name: reminder.name, schedule: schedule, then: reminder.then, next: after?.next, paused: after?.paused ?? false)
    }

    /// This chat's schedule `name`, while there is one.
    private func made(_ name: String, in chat: ConversationID) async throws -> Kept? {
        try await TimerKeeper(on: actorSystem).schedules(of: Self.virtualID(of: space)).first {
            $0.firing.name == ChatReminder.timerName(name, in: chat)
        }
    }
}

/// What it sets due is its chats': it's told when one is, as their owner.
extension Scheduler: TimerOwner {
    /// A chat's schedule is due: it does what it says there.
    public distributed func timerFired(_ firing: Firing, run: WorkflowID) async throws {
        guard let reminder = firing.about(as: ChatReminder.self) else { return }
        try await reminder.doing(run: run, on: actorSystem)
    }
}

/// Read by everyone: what each may change, it decides.
extension Scheduler: AccessControlled {
    /// Everyone in its space may use it, and no one from another.
    public distributed func access(for chain: CallChain) -> Access {
        .readByEveryone
    }
}
