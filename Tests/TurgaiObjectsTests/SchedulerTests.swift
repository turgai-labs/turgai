import DistributedCluster
import DurableWorkflows
import EventSourcing
import Foundation
import Testing
import TurgaiDomain

@testable import TurgaiApplication
@testable import TurgaiObjects

/// A chat's schedules, by the names they're given in it: listed there, and changed by whoever made
/// each, or the chat's admins.
@Suite(.serialized)
struct SchedulerTests {
    static let chat = ConversationID(
        channel: ChannelID(provider: "telegram", instanceID: "bot"), externalAddress: ExternalConversationAddress("42"))
    static let group = GroupID(rawValue: "telegram/bot:42")
    static let ann = CallScope(UserID("ann"), in: group, as: .member, allowed: [])
    static let bob = CallScope(UserID("bob"), in: group, as: .member, allowed: [])

    private func `as`<Answer: Sendable>(_ scope: CallScope, _ body: () async throws -> Answer) async throws -> Answer {
        try await CallChain.$current.withValue(.start(scope, in: Self.chat)) { try await body() }
    }

    @Test(.timeLimit(.minutes(1)))
    func aChatsSchedulesAreListedThereAndChangedByWhoeverMadeThem() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem(
            "scheduler", store: store, hostsVirtualActors: true,
            installing: { $0.plugins.install(plugin: DurableWorkflowsPlugin()) }
        ) { node in
            let scheduler = try await Scheduler.resolve(on: node)
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

            // Someone else's isn't theirs to change; one that isn't there is said with those that are.
            await #expect(throws: DueInChatError.notTheirs("morning-news")) {
                try await self.as(Self.bob) { try await scheduler.cancel(name: "morning-news") }
            }
            await #expect(throws: DueInChatError.none(kind: "schedule", "evening", named: ["morning-news"])) {
                try await self.as(Self.ann) { try await scheduler.cancel(name: "evening") }
            }

            _ = try await self.as(Self.ann) { try await scheduler.cancel(name: "morning-news") }
            #expect(try await self.as(Self.ann) { try await scheduler.list().chat }.isEmpty)
        }
    }
}
