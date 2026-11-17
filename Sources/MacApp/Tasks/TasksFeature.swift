import ComposableArchitecture
import Foundation
import TurgaiModels

/// The shown space's tasks, under its conversations: what's due in it, followed as it changes while
/// it's shown, and what each one's menu does to it.
@Reducer
struct TasksFeature {
    /// A task, as the sidebar lists it: what it's for, when it's due, and whose it is.
    struct Row: Equatable, Identifiable {
        let id: TaskListing.ID
        let title: String
        /// What it does when it's due, when it says.
        let does: String?
        let when: TaskListing.When
        let paused: Bool
        let owner: Owner

        /// What its menu offers: a schedule pauses or resumes, and cancels; a reminder cancels; an
        /// object's own changes only by its code.
        var commands: [Command] {
            switch owner {
            case .schedule(let schedule): [paused ? .resume(schedule) : .pause(schedule), .cancelSchedule(schedule)]
            case .reminder(let reminder): [.cancelReminder(reminder)]
            case .object: []
            }
        }
    }

    /// Whose a task is: a chat's schedule or reminder, or an object's own.
    enum Owner: Equatable {
        case schedule(Named)
        case reminder(Named)
        case object
    }

    /// A chat's schedule or reminder, by the name it's kept under there, in the space the chat is
    /// one of.
    struct Named: Hashable {
        let chat: TaskListing.Chat
        let space: SpaceID
        let name: String
    }

    /// What a task's menu does, to the schedule or reminder it names.
    enum Command: Hashable, Identifiable {
        case pause(Named)
        case resume(Named)
        case cancelSchedule(Named)
        case cancelReminder(Named)

        var id: Self { self }
    }

    @ObservableState
    struct State: Equatable {
        var rows: IdentifiedArrayOf<Row> = []
        /// Whether they're folded under their heading, whichever space is shown.
        var collapsed = false
        /// The task whose info is open, while one's is.
        var shown: TaskListing.ID?
    }

    enum Action {
        /// `space` is shown: its tasks are followed until it isn't.
        case follow(SpaceID)
        /// Their heading: they're folded under it, or shown again.
        case headingTapped
        /// A task clicked: its info opens.
        case rowTapped(TaskListing.ID)
        /// Its info closed.
        case infoDismissed
        /// The tasks, as they are as they're followed.
        case current([Row])
        /// One, as it's kept now: new, or changed.
        case kept(Row)
        /// The one with this id isn't due any more.
        case ended(TaskListing.ID)
        /// Something picked from a task's menu.
        case picked(Command)
        case delegate(Delegate)

        enum Delegate: Equatable {
            /// What went wrong, to show.
            case failed(String)
        }
    }

    private enum CancelID { case following }

    @Dependency(\.chat) var chat

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .follow(let space):
                state.rows = []
                state.shown = nil
                return follow(space).cancellable(id: CancelID.following, cancelInFlight: true)

            case .headingTapped:
                state.collapsed.toggle()
                return .none

            case .rowTapped(let id):
                state.shown = id
                return .none

            case .infoDismissed:
                state.shown = nil
                return .none

            case .current(let rows):
                state.rows = IdentifiedArray(uniqueElements: rows)
                if let shown = state.shown, state.rows[id: shown] == nil { state.shown = nil }
                return .none

            case .kept(let row):
                state.rows.updateOrAppend(row)
                return .none

            case .ended(let id):
                state.rows.remove(id: id)
                if state.shown == id { state.shown = nil }
                return .none

            case .picked(let command):
                // What it changed comes as the task kept, or ended.
                return .run { send in
                    do {
                        try await chat.perform(command.ask)
                    } catch ChatSocketError.failed(let error) {
                        await send(.delegate(.failed(error.message)))
                    } catch {
                        await send(.delegate(.failed("Couldn't change the task.")))
                    }
                }

            case .delegate:
                return .none
            }
        }
    }

    /// `space`'s tasks: what they are, then each change, until it's cancelled; then they're left.
    private func follow(_ space: SpaceID) -> Effect<Action> {
        .run { send in
            // Listened to before it's joined, so what's written as it's joined is heard.
            let heard = await chat.events()
            do {
                try await chat.perform(.join(.tasks(space: space)))
            } catch {
                await send(.delegate(.failed("Couldn't show the space's tasks.")))
                return
            }
            for await event in heard {
                switch event.payload {
                case .tasks(space, let tasks): await send(.current(tasks.map { Row($0, in: space) }))
                case .taskKept(space, let task): await send(.kept(Row(task, in: space)))
                case .taskEnded(space, let id): await send(.ended(id))
                default: break
                }
            }
            try? await chat.perform(.leave(.tasks(space: space)))
        }
    }
}

extension TasksFeature.Row {
    /// `listing`, one of `space`'s tasks, as the connection says it.
    init(_ listing: TaskListing, in space: SpaceID) {
        let owner: TasksFeature.Owner =
            switch listing.kind {
            case .schedule(let chat, let name): .schedule(TasksFeature.Named(chat: chat, space: space, name: name))
            case .reminder(let chat, let name): .reminder(TasksFeature.Named(chat: chat, space: space, name: name))
            case .object: .object
            }
        self.init(
            id: listing.id, title: listing.title, does: listing.does, when: listing.when, paused: listing.paused,
            owner: owner)
    }
}

extension TasksFeature.Command {
    /// What it asks the connection.
    var ask: ChatAsk {
        switch self {
        case .pause(let schedule):
            .changeSchedule(in: schedule.chat, of: schedule.space, named: schedule.name, .pause)
        case .resume(let schedule):
            .changeSchedule(in: schedule.chat, of: schedule.space, named: schedule.name, .resume)
        case .cancelSchedule(let schedule):
            .changeSchedule(in: schedule.chat, of: schedule.space, named: schedule.name, .cancel)
        case .cancelReminder(let reminder): .cancelReminder(in: reminder.chat, of: reminder.space, named: reminder.name)
        }
    }
}
