import DistributedCluster
import DurableWorkflows
import EventSourcing
import Foundation
import Testing
import TurgaiCalls
import TurgaiDomain

@testable import TurgaiApplication
@testable import TurgaiObjects
@testable import TurgaiSpaces

/// A chat's schedules, by the names they're given in it: listed there, and changed by whoever made
/// each, or the chat's admins.
@Suite(.serialized)
struct SchedulerTests {
    static let chat = ConversationID(
        channel: ChannelID(provider: "telegram", instanceID: "bot"), externalAddress: ExternalConversationAddress("42"))
    static let space = SpaceID()
    static let ann = CallScope.member(UserID.ann, in: space)
    static let bob = CallScope.member(UserID.bob, in: space)

    private func `as`<Answer: Sendable>(_ scope: CallScope, _ body: () async throws -> Answer) async throws -> Answer {
        try await CallChain.$current.withValue(.start(scope, in: Self.chat)) { try await body() }
    }

    @Test(.timeLimit(.minutes(1)))
    func aChatsSchedulesAreListedThereAndChangedByWhoeverIsInIt() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem(
            "scheduler", store: store, hostsVirtualActors: true, people: [Self.ann, Self.bob],
            installing: { $0.plugins.install(plugin: DurableWorkflowsPlugin()) }
        ) { node in
            let scheduler = try await Scheduler.of(Self.space, on: node)
            let (listener, heard) = try await listening(to: Self.space, as: Self.ann, on: node)
            defer { listener.cancel() }
            let made = try await self.as(Self.ann) {
                try await scheduler.every(
                    name: "Morning News", schedule: .daily(hour: 8, minute: 0, timeZone: "Europe/Berlin"),
                    then: .ask(instruction: "Tell me the news"))
            }
            // Named as ids are, which a chat's commands take.
            #expect(made.name == "morning-news")
            #expect(made.next != nil)
            #expect(try await self.as(Self.ann) { try await scheduler.list().chat.map(\.name) } == ["morning-news"])

            let paused = try await self.as(Self.ann) { try await scheduler.pause(name: "morning-news") }
            #expect(paused.paused)
            let resumed = try await self.as(Self.ann) { try await scheduler.resume(name: "morning-news") }
            #expect(!resumed.paused)

            // One that isn't there is said with those that are.
            await #expect(throws: DueInChatError.none(kind: "schedule", "evening", named: ["morning-news"])) {
                try await self.as(Self.ann) { try await scheduler.cancel(name: "evening") }
            }

            // It's the chat's: Bob, who's in the chat too, sees it and ends it, though Ann made it.
            #expect(try await self.as(Self.bob) { try await scheduler.list().chat.map(\.name) } == ["morning-news"])
            _ = try await self.as(Self.bob) { try await scheduler.cancel(name: "morning-news") }
            #expect(try await self.as(Self.ann) { try await scheduler.list().chat }.isEmpty)

            // Whoever follows the space's tasks is told each change as it's made, of the one kept.
            let notices = await heard.notices(4)
            guard case .kept(let first) = notices.first else {
                Issue.record("The schedule wasn't told as kept first: \(notices)")
                return
            }
            func kept(paused: Bool) -> TasksNotice {
                .kept(
                    KeptTask(
                        id: first.id, of: .chat(Self.chat, name: "morning-news", does: "asks Tell me the news"),
                        due: .schedule(.daily(hour: 8, minute: 0, timeZone: "Europe/Berlin")), paused: paused))
            }
            #expect(notices == [kept(paused: false), kept(paused: true), kept(paused: false), .ended(first.id)])
        }
    }
}
