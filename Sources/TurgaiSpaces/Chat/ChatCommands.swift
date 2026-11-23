import DistributedCluster
import TurgaiCalls
import TurgaiDomain
import TurgaiObjects

#if canImport(FoundationEssentials)
    import FoundationEssentials
    import FoundationInternationalization
#else
    import Foundation
#endif

/// A command someone gives in one of a space's chats, about what's due there and the objects they
/// may use: the space takes it, as it takes a message, and shows its answer in the chat.
public enum InChatCommand: Codable, Sendable, Equatable {
    /// The chat's timers.
    case reminders
    /// The chat's schedules.
    case tasks
    /// A change to the chat's schedule of that name.
    case changeTask(TaskChange, name: String)
    /// The chat's timer of that name cancelled.
    case cancelReminder(name: String)
    /// The objects they may use.
    case objects
    /// One of those objects' card, by its handle as listed.
    case object(String)

    /// A change to one of a chat's schedules.
    public enum TaskChange: Codable, Sendable, Equatable {
        case pause, resume, cancel
    }
}

extension Space {
    /// `command`, given by `person` in its conversation `conversation`: done as they may do it,
    /// with its answer shown there. Refused unless they're one of the conversation's people.
    public distributed func command(_ command: InChatCommand, in conversation: ConversationID, for person: UserID)
        async throws
    {
        let commands = ChatCommands(space: self, conversation: conversation, person: person, system: actorSystem)
        switch command {
        case .reminders: try await commands.reminders()
        case .tasks: try await commands.tasks()
        case .changeTask(let change, let name): try await commands.change(change, named: name)
        case .cancelReminder(let name): try await commands.cancelReminder(named: name)
        case .objects: try await commands.objects()
        case .object(let handle): try await commands.object(handle)
        }
    }
}

/// How a space does a chat's command: asked of its scheduler, its timers and its objects for the
/// person, and shown in the chat.
struct ChatCommands {
    let space: Space
    let conversation: ConversationID
    let person: TurgaiDomain.UserID
    let system: ClusterSystem

    typealias TaskChange = InChatCommand.TaskChange

    /// The chat's timers and its objects', as the timers object lists them for `person`.
    func reminders() async throws {
        let (text, actions) = DuePresentation.reminders(
            try await asking { system, space in try await Timers.of(space, on: system).list() })
        try await show(text, actions: actions)
    }

    /// The chat's schedules and its objects', as the scheduler lists them for `person`.
    func tasks() async throws {
        let (text, actions) = DuePresentation.tasks(
            try await asking { system, space in try await Scheduler.of(space, on: system).list() })
        try await show(text, actions: actions)
    }

    /// `change` to the chat's schedule `name`, as the scheduler makes it for `person`: refused,
    /// with why, when it isn't theirs to make.
    func change(_ change: TaskChange, named name: String) async throws {
        do {
            let changed = try await asking { system, space in
                let scheduler = try await Scheduler.of(space, on: system)
                switch change {
                case .pause: return try await scheduler.pause(name: name)
                case .resume: return try await scheduler.resume(name: name)
                case .cancel: return try await scheduler.cancel(name: name)
                }
            }
            let verb =
                switch change {
                case .pause: "paused"
                case .resume: "resumed"
                case .cancel: "cancelled"
                }
            try await show(DuePresentation.action(verb, id: changed.name))
        } catch {
            try await show("\(error)")
        }
    }

    /// The chat's timer `name` cancelled, as the timers object does for `person`: refused, with
    /// why, when it isn't theirs to cancel.
    func cancelReminder(named name: String) async throws {
        do {
            let cancelled = try await asking { system, space in
                try await Timers.of(space, on: system).cancel(name: name)
            }
            try await show(DuePresentation.reminderAction("cancelled", id: cancelled.name))
        } catch {
            try await show("\(error)")
        }
    }

    /// The objects `person` may read here, made by name, each a button that shows its card.
    func objects() async throws {
        let objects = try await asking { system, space in
            try await ObjectSession(in: space, actorSystem: system, agents: [], builtIns: []).yourObjects()
        }
        try await show(
            objects.isEmpty ? "No objects." : "Objects:",
            actions: objects.map { OutboundAction(label: $0.description, command: "/object \($0)") })
    }

    /// The card of `person`'s object `written`, as they may read it here: refused, with why, when
    /// it isn't one of theirs.
    func object(_ written: String) async throws {
        do {
            let card = try await asking { system, space in
                let session = try await ObjectSession(in: space, actorSystem: system, agents: [], builtIns: [])
                let objects = try await session.yourObjects()
                guard let object = objects.first(where: { $0.description == written }) else {
                    throw NotYourObject(written: written, yours: objects.map(\.description))
                }
                return try await session.card(object)
            }
            switch card {
            case .markdown(let text): try await show(text)
            }
        } catch {
            try await show("\(error)")
        }
    }

    /// `ask`'s answer, asked of an object of the space, or a built-in one, on behalf of `person`, in
    /// the chat: with their scope in its space, which asking spends nothing of. Refused unless
    /// they're one of its people.
    private func asking<Answer: Sendable>(_ ask: @Sendable (ClusterSystem, SpaceID) async throws -> Answer)
        async throws -> Answer
    {
        _ = try await space.reading(conversation, by: person)
        let scope = try await space.scope(of: person)
        let system = self.system
        return try await CallChain.$current.withValue(.start(scope, in: conversation)) {
            try await ask(system, scope.space)
        }
    }

    private func show(_ text: String, actions: [OutboundAction] = []) async throws {
        try await space.showNotice(text, actions: actions, in: conversation)
    }
}

/// Why an object can't be shown: it isn't one of the person's here, with those that are.
struct NotYourObject: Error, CustomStringConvertible {
    let written: String
    let yours: [String]

    var description: String {
        "`\(written)` isn't one of your objects here"
            + (yours.isEmpty ? "" : "; yours: " + yours.map { "`\($0)`" }.joined(separator: ", "))
    }
}

enum DuePresentation {
    private enum Command {
        static let cancelReminder = "/cancel-reminder"
        static let pauseTask = "/pause-task"
        static let unpauseTask = "/unpause-task"
        static let cancelTask = "/cancel-task"
    }

    static func reminders(_ timers: TimersInChat) -> (String, [OutboundAction]) {
        guard !timers.chat.isEmpty || !timers.objects.isEmpty else { return ("No active reminders.", []) }
        var lines: [String] = []
        var actions: [OutboundAction] = []
        for timer in timers.chat {
            switch timer.then {
            case .say(let text): lines.append("\(timer.name): says \(text)")
            case .ask(let instruction): lines.append("\(timer.name): asks \(instruction)")
            }
            lines.append("  At: \(timer.date.formatted(date: .abbreviated, time: .shortened))")
            actions.append(OutboundAction(label: "Cancel", command: "\(Command.cancelReminder) \(timer.name)"))
        }
        // An object's own timers, which its code changes.
        for timer in timers.objects {
            lines.append("\(timer.object) · \(timer.property)")
            lines.append("  At: \(timer.date.formatted(date: .abbreviated, time: .shortened))")
        }
        return (lines.joined(separator: "\n"), actions)
    }

    static func tasks(_ scheduled: SchedulesInChat) -> (String, [OutboundAction]) {
        guard !scheduled.chat.isEmpty || !scheduled.objects.isEmpty else { return ("No active tasks.", []) }
        var lines: [String] = []
        var actions: [OutboundAction] = []
        func next(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .shortened) ?? "unknown" }
        for schedule in scheduled.chat {
            switch schedule.then {
            case .say(let text): lines.append("\(schedule.name): says \(text)")
            case .ask(let instruction): lines.append("\(schedule.name): asks \(instruction)")
            }
            lines.append("  \(schedule.schedule.described)")
            lines.append("  Next: \(next(schedule.next))")
            lines.append("  Status: \(schedule.paused ? "paused" : "active")")
            actions.append(
                OutboundAction(
                    label: schedule.paused ? "Resume" : "Pause",
                    command: "\(schedule.paused ? Command.unpauseTask : Command.pauseTask) \(schedule.name)"))
            actions.append(OutboundAction(label: "Cancel", command: "\(Command.cancelTask) \(schedule.name)"))
        }
        // An object's own schedules, which its code changes.
        for schedule in scheduled.objects {
            lines.append("\(schedule.object) · \(schedule.property)")
            lines.append("  \(schedule.schedule.described)")
            lines.append("  Next: \(next(schedule.next))")
        }
        return (lines.joined(separator: "\n"), actions)
    }

    static func action(_ verb: String, id: String) -> String {
        "Task \(id) \(verb)."
    }

    static func reminderAction(_ verb: String, id: String) -> String {
        "Reminder \(id) \(verb)."
    }
}
