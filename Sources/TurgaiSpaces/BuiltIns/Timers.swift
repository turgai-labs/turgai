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

/// A chat's timer, as it's listed: its name, when it's due, and what it does then.
@Describable
public struct TimerInChat: Codable, Sendable, Equatable {
    public let name: String
    public let date: Date
    public let then: WhenDue
}

/// An object's timer in a chat, as it's listed: the object, its property that holds it, and when
/// it's due. Its object's code changes or ends it.
@Describable
public struct ObjectTimerInChat: Codable, Sendable, Equatable {
    public let object: String
    public let property: String
    public let date: Date
}

/// What's due once in a chat: its own timers, and its objects'.
@Describable
public struct TimersInChat: Codable, Sendable, Equatable {
    public let chat: [TimerInChat]
    public let objects: [ObjectTimerInChat]
}

/// The chats' timers: each due once, at its date, by the name it's given in its chat, saying text
/// there or asking the chat's agent. It's told when one is due, as their owner. What an object's own
/// timers are, it lists.
@Discoverable
@VirtualActor
public distributed actor Timers {
    public typealias ActorSystem = ClusterSystem
    public typealias Dependency = SpaceID

    /// The space whose it is.
    private let space: SpaceID

    /// `space`'s timers, wherever and whenever it runs.
    public static func of(_ space: SpaceID, on actorSystem: ClusterSystem) async throws -> Timers {
        try await actorSystem.virtualActors.getActor(identifiedBy: virtualID(of: space), dependency: space)
    }

    /// The id of `space`'s timers.
    static func virtualID(of space: SpaceID) -> VirtualActorID {
        .owned(by: space, "builtin", "timers")
    }

    public init(actorSystem: ActorSystem, dependency space: SpaceID) async throws {
        self.actorSystem = actorSystem
        self.space = space
    }

    /// Sets the timer `name` in this chat for `date`, in place of the one of that name: due once
    /// then, doing `then`.
    /// - Parameters:
    ///   - name: The timer's name in this chat.
    ///   - date: When it's due.
    ///   - then: What it does when it's due.
    @DiscoverableAction
    public distributed func at(name: String, date: Date, then: WhenDue) async throws -> TimerInChat {
        guard date > Date.now else { throw DueInChatError.past(date) }
        return try await setting(name, at: date, then: then)
    }

    /// Sets the timer `name` in this chat for `minutes` from now, in place of the one of that name:
    /// due once then, doing `then`.
    /// - Parameters:
    ///   - name: The timer's name in this chat.
    ///   - minutes: How many minutes from now it's due.
    ///   - then: What it does when it's due.
    @DiscoverableAction
    public distributed func after(name: String, minutes: Int, then: WhenDue) async throws -> TimerInChat {
        guard minutes > 0 else { throw DueInChatError.noMinutes(minutes) }
        return try await setting(name, at: Date.now.addingTimeInterval(TimeInterval(minutes * 60)), then: then)
    }

    /// What's due once in this chat: its timers, and its objects'.
    @DiscoverableAction(safe: true, idempotent: true)
    public distributed func list() async throws -> TimersInChat {
        let (chain, chat) = try DueInChatError.chat()
        let timers = try await running(in: chat).map { _, reminder, date in
            TimerInChat(name: reminder.name, date: date, then: reminder.then)
        }
        let objects = try await TimerKeeper(on: actorSystem).timers().compactMap { now -> ObjectTimerInChat? in
            guard let object = now.firing.about(as: ObjectTimerAbout.self), object.space == chain.scope.space,
                object.place == chat, case .timer(let timer) = now.firing.due
            else { return nil }
            return ObjectTimerInChat(object: object.object.rawValue, property: now.firing.name, date: timer.date)
        }
        return TimersInChat(
            chat: timers.sorted { $0.date < $1.date }, objects: objects.sorted { $0.date < $1.date })
    }

    /// Cancels this chat's timer `name`: it isn't due.
    /// - Parameter name: The timer's name in this chat.
    @DiscoverableAction
    public distributed func cancel(name written: String) async throws -> TimerInChat {
        let (chain, chat) = try DueInChatError.chat()
        let name = ObjectNames.handle(for: written)
        let running = try await running(in: chat)
        guard let (id, reminder, date) = running.first(where: { $0.reminder.name == name }) else {
            throw DueInChatError.none(kind: "timer", written, named: running.map(\.reminder.name).sorted())
        }
        try await TimerKeeper(on: actorSystem).cancel(id)
        await actorSystem.tellTasks(in: chain.scope.space, .ended(id))
        return TimerInChat(name: reminder.name, date: date, then: reminder.then)
    }

    /// Sets the timer `written` in this chat for `date`, in place of the one of that name.
    private func setting(_ written: String, at date: Date, then: WhenDue) async throws -> TimerInChat {
        let (chain, chat) = try DueInChatError.chat()
        let name = ObjectNames.handle(for: written)
        guard !name.trimmed().isEmpty else { throw DueInChatError.unnamed }
        try DueInChatError.askable(then, chain)
        let keeper = TimerKeeper(on: actorSystem)
        let me = try await Self.of(space, on: actorSystem)
        let timerName = ChatReminder.timerName(name, in: chat)
        for ended in try await keeper.cancel(timerName, of: me) {
            await actorSystem.tellTasks(in: chain.scope.space, .ended(ended))
        }
        let reminder = ChatReminder(
            name: name, then: then, askedBy: chain.scope.asker, in: chain.scope.space, conversationID: chat)
        let id = try await keeper.set(timerName, at: .at(date), of: me, about: reminder)
        await actorSystem.tellTasks(
            in: chain.scope.space,
            .kept(KeptTask(id: id, of: .chat(chat, name: name, does: then.described), due: .timer(.at(date)), paused: false)))
        return TimerInChat(name: name, date: date, then: then)
    }

    /// The timers of the chat `chat` that aren't due yet, each with its id and date.
    private func running(in chat: ConversationID) async throws -> [(id: TimerID, reminder: ChatReminder, date: Date)] {
        try await TimerKeeper(on: actorSystem).timers(of: Self.virtualID(of: space)).compactMap { now in
            guard let reminder = now.firing.about(as: ChatReminder.self), reminder.conversationID == chat,
                case .timer(let timer) = now.firing.due
            else { return nil }
            return (now.firing.id, reminder, timer.date)
        }
    }
}

/// What it sets due is its chats': it's told when one is, as their owner.
extension Timers: TimerOwner {
    /// A chat's timer is due: it does what it says there, once, and isn't a timer any more.
    public distributed func timerFired(_ firing: Firing, run: WorkflowID) async throws {
        guard let reminder = firing.about(as: ChatReminder.self) else { return }
        try await reminder.doing(run: run, on: actorSystem)
        await actorSystem.tellTasks(in: reminder.space, .ended(firing.id))
    }
}

/// Read by everyone: what each may change, it decides.
extension Timers: AccessControlled {
    /// Everyone in its space may use it, and no one from another.
    public distributed func access(for chain: CallChain) -> Access {
        .readByEveryone
    }
}
