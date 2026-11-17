import ComposableArchitecture
import Foundation
import Testing
import TurgaiModels

@testable import MacApp

@MainActor
struct TasksFeatureTests {
    /// The shown space's tasks are followed: they come as they are as it's joined, then each change of
    /// its own; a task's menu does what its chat's commands do, what it changed coming as it's kept,
    /// or ended. A task's info opens as it's clicked, and closes as it ends. Another space shown, that
    /// one's are followed instead, and this one's left.
    @Test
    func theShownSpacesTasksAreFollowed() async {
        let turgai = SpaceID(rawValue: "turgai")
        let family = SpaceID(rawValue: "family")
        let chat = TaskListing.Chat(rawValue: "turgai:dinner")
        let news = TaskListing(
            id: TaskListing.ID(rawValue: "news"), title: "news", does: "asks for the news",
            when: .repeating("daily at 08:00 (Europe/Berlin)"), paused: false, kind: .schedule(in: chat, named: "news"))
        let paused = TaskListing(
            id: news.id, title: "news", does: "asks for the news", when: .repeating("daily at 08:00 (Europe/Berlin)"),
            paused: true, kind: .schedule(in: chat, named: "news"))
        let tea = TaskListing(
            id: TaskListing.ID(rawValue: "tea"), title: "tea", does: "says Tea's ready",
            when: .once(Date(timeIntervalSince1970: 60)), paused: false, kind: .reminder(in: chat, named: "tea"))
        let tick = TaskListing(
            id: TaskListing.ID(rawValue: "tick"), title: "ticker · tick", does: nil,
            when: .repeating("every 5 minutes"),
            paused: false, kind: .object)
        let schedule = TasksFeature.Named(chat: chat, space: turgai, name: "news")
        let reminder = TasksFeature.Named(chat: chat, space: turgai, name: "tea")

        // As the connection does: each listener hears what's said; a space's tasks are said as it's
        // joined.
        let listeners = LockIsolated<[AsyncStream<ChatEvent>.Continuation]>([])
        let tell = { @Sendable (payload: ChatEvent.Payload) in
            for listener in listeners.value { listener.yield(ChatEvent(payload: payload)) }
        }
        let asked = LockIsolated<[ChatAsk]>([])
        let store = TestStore(initialState: TasksFeature.State()) {
            TasksFeature()
        } withDependencies: {
            $0.chat.events = {
                let (events, listener) = AsyncStream.makeStream(of: ChatEvent.self)
                listeners.withValue { $0.append(listener) }
                return events
            }
            $0.chat.ask = { ask in
                asked.withValue { $0.append(ask) }
                switch ask {
                case .join(.tasks(let space)):
                    tell(.tasks(space: space, tasks: space == turgai ? [news, tea, tick] : []))
                case .changeSchedule(_, _, _, .cancel): return .failed(ChatError(code: "refused", message: "No."))
                default: break
                }
                return .ok
            }
        }

        await store.send(.follow(turgai))
        await store.receive(\.current) {
            $0.rows = [.init(news, in: turgai), .init(tea, in: turgai), .init(tick, in: turgai)]
        }
        #expect(
            store.state.rows.map(\.commands) == [
                [.pause(schedule), .cancelSchedule(schedule)], [.cancelReminder(reminder)], [],
            ])
        // Their heading folds them away, and shows them again.
        await store.send(.headingTapped) { $0.collapsed = true }
        await store.send(.headingTapped) { $0.collapsed = false }
        await store.send(.rowTapped(news.id)) { $0.shown = news.id }
        await store.send(.infoDismissed) { $0.shown = nil }

        // A change in another space isn't heard; one in this space changes its row.
        tell(.taskKept(space: family, task: tick))
        tell(.taskKept(space: turgai, task: paused))
        await store.receive(\.kept) { $0.rows[id: news.id] = .init(paused, in: turgai) }
        #expect(store.state.rows.first?.commands == [.resume(schedule), .cancelSchedule(schedule)])

        await store.send(.picked(.resume(schedule)))
        await store.send(.picked(.cancelReminder(reminder)))
        await store.send(.rowTapped(tea.id)) { $0.shown = tea.id }
        tell(.taskEnded(space: turgai, id: tea.id))
        await store.receive(\.ended) {
            $0.rows.remove(id: tea.id)
            $0.shown = nil
        }
        await store.send(.picked(.cancelSchedule(schedule)))
        await store.receive(\.delegate, .failed("No."))

        let shown = await store.send(.follow(family)) { $0.rows = [] }
        await store.receive(\.current)
        await shown.cancel()
        await store.finish()
        #expect(
            Array(asked.value.prefix(4)) == [
                .join(.tasks(space: turgai)), .changeSchedule(in: chat, of: turgai, named: "news", .resume),
                .cancelReminder(in: chat, of: turgai, named: "tea"),
                .changeSchedule(in: chat, of: turgai, named: "news", .cancel),
            ])
        // One space left as another is followed: two topics, in either order.
        #expect(asked.value.count == 7)
        #expect(asked.value.contains(.leave(.tasks(space: turgai))))
        #expect(asked.value.contains(.join(.tasks(space: family))))
        #expect(asked.value.contains(.leave(.tasks(space: family))))
    }
}
