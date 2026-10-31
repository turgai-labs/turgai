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
/// there or asking the chat's agent. What an object's own timers are, it lists.
@Discoverable
@VirtualActor
public distributed actor Timers {
    public typealias ActorSystem = ClusterSystem
    public typealias Dependency = ObjectIdentity

    public init(actorSystem: ActorSystem, dependency: ObjectIdentity) async throws {
        self.actorSystem = actorSystem
    }

    /// The one set of timers, by the id it always has.
    public static func resolve(on actorSystem: ClusterSystem) async throws -> Timers {
        try await actorSystem.virtualActors.getActor(identifiedBy: actorID, dependency: identity)
    }

    /// Lists it among the objects by its lasting reference.
    public static func start(on actorSystem: ClusterSystem) async throws {
        let timers = try await resolve(on: actorSystem)
        let object = try DiscoverableObject.resolve(id: timers.id, using: actorSystem)
        await actorSystem.receptionist.checkIn(object, with: .objects)
    }

    static let identity = ObjectIdentity(rawValue: "timers")
    static let actorID = VirtualActorID(rawValue: "builtin/timers")

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
        let (_, chat) = try DueInChatError.chat()
        let timers = try await running(in: chat).map { _, timer in
            TimerInChat(name: timer.name, date: timer.date, then: timer.then)
        }
        let decoder = JSONDecoder()
        let objects = try await actorSystem.workflows.listWorkflows(workflow: ObjectTimerWorkflow.self).compactMap {
            description -> ObjectTimerInChat? in
            guard case .running = description.status, let data = description.inputData,
                let firing = try? decoder.decode(ObjectFiring.self, from: data), firing.place == chat,
                case .timer(let timer) = firing.due
            else { return nil }
            return ObjectTimerInChat(object: firing.object.rawValue, property: firing.property, date: timer.date)
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
        guard let (id, timer) = running.first(where: { $0.timer.name == name }) else {
            throw DueInChatError.none(kind: "timer", written, named: running.map(\.timer.name).sorted())
        }
        guard DueInChatError.mayChange(madeBy: timer.ownerID, chain) else { throw DueInChatError.notTheirs(name) }
        try await actorSystem.workflows.cancel(type: TimerWorkflow.self, options: WorkflowOptions(id: id))
        return TimerInChat(name: timer.name, date: timer.date, then: timer.then)
    }

    /// Sets the timer `written` in this chat for `date`, in place of the one of that name.
    private func setting(_ written: String, at date: Date, then: WhenDue) async throws -> TimerInChat {
        let (chain, chat) = try DueInChatError.chat()
        let name = ObjectNames.handle(for: written)
        guard !name.trimmed().isEmpty else { throw DueInChatError.unnamed }
        let workflows = actorSystem.workflows
        if let (id, before) = try await running(in: chat).first(where: { $0.timer.name == name }) {
            guard DueInChatError.mayChange(madeBy: before.ownerID, chain) else {
                throw DueInChatError.notTheirs(name)
            }
            try await workflows.cancel(type: TimerWorkflow.self, options: WorkflowOptions(id: id))
        }
        let timer = ChatTimer(name: name, date: date, then: then, ownerID: chain.scope.person, conversationID: chat)
        try await workflows.start(
            type: TimerWorkflow.self,
            options: WorkflowOptions(
                id: ChatTimer.id(in: chat, named: name, at: date), retryPolicy: ChatSchedule.retryPolicy),
            input: timer)
        return TimerInChat(name: name, date: date, then: then)
    }

    /// This chat's timers that aren't due yet, each with its workflow.
    private func running(in chat: ConversationID) async throws -> [(id: WorkflowID, timer: ChatTimer)] {
        let decoder = JSONDecoder()
        return try await actorSystem.workflows.listWorkflows(workflow: TimerWorkflow.self).compactMap {
            description -> (WorkflowID, ChatTimer)? in
            guard case .running = description.status, let data = description.inputData,
                let timer = try? decoder.decode(ChatTimer.self, from: data), timer.conversationID == chat
            else { return nil }
            return (description.id, timer)
        }
    }
}

/// Read by everyone: what each may change, it decides.
extension Timers: AccessControlled {
    public func access(for chain: CallChain) -> Access { .readByEveryone }
}
