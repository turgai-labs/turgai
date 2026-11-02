import DistributedCluster
import DurableWorkflows
import EventSourcing
import Foundation
import Testing
import TurgaiDomain

@testable import TurgaiApplication
@testable import TurgaiObjects
import TurgaiCalls

/// A chat's timers, by the names they're given in it: each due once, listed there, and cancelled by
/// whoever set it, or the chat's admins.
@Suite(.serialized)
struct TimersTests {
    static let chat = ConversationID(
        channel: ChannelID(provider: "telegram", instanceID: "bot"), externalAddress: ExternalConversationAddress("42"))
    static let space = SpaceID()
    static let ann = CallScope(UserID.ann, in: space, as: .member, allowed: [])
    static let bob = CallScope(UserID.bob, in: space, as: .member, allowed: [])

    private func `as`<Answer: Sendable>(_ scope: CallScope, _ body: () async throws -> Answer) async throws -> Answer {
        try await CallChain.$current.withValue(.start(scope, in: Self.chat)) { try await body() }
    }

    @Test(.timeLimit(.minutes(1)))
    func aChatsTimersAreListedThereAndCancelledByWhoeverSetThem() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem(
            "timers-object", store: store, hostsVirtualActors: true, people: [Self.ann, Self.bob],
            installing: { $0.plugins.install(plugin: DurableWorkflowsPlugin()) }
        ) { node in
            let timers = try await Timers.resolve(on: node)
            let set = try await self.as(Self.ann) {
                try await timers.after(name: "Tea", minutes: 30, then: .say(text: "Tea's ready"))
            }
            #expect(set.name == "tea")
            #expect(set.date > Date.now.addingTimeInterval(29 * 60))
            #expect(try await self.as(Self.ann) { try await timers.list().chat.map(\.name) } == ["tea"])

            // What can't be due isn't set.
            await #expect(throws: DueInChatError.noMinutes(0)) {
                try await self.as(Self.ann) { try await timers.after(name: "now", minutes: 0, then: .say(text: "Now")) }
            }
            let past = Date(timeIntervalSince1970: 0)
            await #expect(throws: DueInChatError.past(past)) {
                try await self.as(Self.ann) { try await timers.at(name: "then", date: past, then: .say(text: "Then")) }
            }

            // Someone else's isn't theirs to cancel; one that isn't there is said with those that are.
            await #expect(throws: DueInChatError.notTheirs("tea")) {
                try await self.as(Self.bob) { try await timers.cancel(name: "tea") }
            }
            await #expect(throws: DueInChatError.none(kind: "timer", "coffee", named: ["tea"])) {
                try await self.as(Self.ann) { try await timers.cancel(name: "coffee") }
            }

            _ = try await self.as(Self.ann) { try await timers.cancel(name: "tea") }
            #expect(try await self.as(Self.ann) { try await timers.list().chat }.isEmpty)
        }
    }
}
