import ComposableArchitecture
import Foundation
import TurgaiModels

/// The shown space's tasks, under its conversations: what's due in it, followed as it changes while
/// it's shown, and what each one's menu does to it.
@Reducer
package struct TasksFeature {
    package init() {}

    /// A task, as the sidebar lists it: what it's for, when it's due, and whose it is.
    package struct Row: Equatable, Identifiable {
        package let id: TaskListing.ID
        package let title: String
        /// What it does when it's due, when it says.
        package let does: String?
        package let when: TaskListing.When
        package let paused: Bool
        package let owner: Owner

        /// What its menu offers: a schedule pauses or resumes, and cancels; a reminder cancels; an
        /// object's own changes only by its code.
        package var commands: [Command] {
            switch owner {
            case .schedule(let schedule): [paused ? .resume(schedule) : .pause(schedule), .cancelSchedule(schedule)]
            case .reminder(let reminder): [.cancelReminder(reminder)]
            case .object: []
            }
        }
    }

    /// Whose a task is: a chat's schedule or reminder, or an object's own.
    package enum Owner: Equatable {
        case schedule(Named)
        case reminder(Named)
        case object
    }

    /// A chat's schedule or reminder, by the name it's kept under there, in the space the chat is
    /// one of.
    package struct Named: Hashable {
        package let chat: TaskListing.Chat
        package let space: SpaceID
        package let name: String
    }

    /// What a task's menu does, to the schedule or reminder it names.
    package enum Command: Hashable, Identifiable {
        case pause(Named)
        case resume(Named)
        case cancelSchedule(Named)
        case cancelReminder(Named)

        package var id: Self { self }
    }

    @ObservableState
    package struct State: Equatable {
        package var rows: IdentifiedArrayOf<Row> = []
        /// Whether they're folded under their heading, whichever space is shown.
        package var collapsed = false
        /// The task whose info is open, while one's is.
        package var shown: TaskListing.ID?
    }

    package enum Action {
        /// `space` is shown: its tasks are followed until it isn't.
        case follow(SpaceID?)
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

        package enum Delegate: Equatable {
            /// What went wrong, to show.
            case failed(String)
        }
    }

    private enum CancelID { case following }

    @Dependency(\.chat) package var chat

    package var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .follow(let space):
                state.rows = []
                state.shown = nil
                guard let space else { return .cancel(id: CancelID.following) }
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
                    } catch LiveSocketError.failed(let error) {
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
            // Listened to before it's joined, so no change after its answer goes unheard; what
            // they are now, its answer tells.
            let heard = await chat.events()
            do {
                if let now = try await chat.join(.tasks(space: space)),
                    case .tasks(space, let tasks) = now.payload
                {
                    await send(.current(tasks.map { Row($0, in: space) }))
                }
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
    package init(_ listing: TaskListing, in space: SpaceID) {
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
    package var ask: LiveAsk {
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
