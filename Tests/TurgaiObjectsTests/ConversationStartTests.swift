import Testing
import TurgaiDomain
import TurgaiSpaces

@testable import TurgaiApplication

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A conversation starts once, in a space, answered by its agent: one in Turgai's apps in a space
/// its first person is in, and a channel's chat in a space made for it, named after it.
@Suite
struct ConversationStartTests {
    /// A conversation in Turgai's apps starts in a space whoever starts it is in, and only its
    /// people read it.
    @Test func anAppsConversationStartsInASpaceItsFirstPersonIsIn() async throws {
        try await withClusterSystem("start", store: MemoryEventStore(), hostsVirtualActors: true, people: []) {
            system in
            let family = try await Spaces(actorSystem: system).make(named: SpaceName("Family")!, by: .ann)
            let chat = try await Conversation.resolve(
                on: system,
                conversationID: ConversationID(channel: ChannelID("turgai"), externalAddress: .init(UUID().uuidString)))
            await #expect(throws: ConversationRefusal.notStarted) { try await chat.history(for: .ann) }
            await #expect(throws: SpaceRefusal.notInIt) {
                try await chat.start(in: family.id, agent: "conversation", by: .bob)
            }

            try await chat.start(in: family.id, agent: "conversation", by: .ann)
            #expect(try await chat.reading(by: .ann) == ConversationStart(in: family.id, agent: "conversation"))
            await #expect(throws: ConversationRefusal.alreadyStarted) {
                try await chat.start(in: family.id, agent: "other", by: .ann)
            }
            await #expect(throws: ConversationRefusal.notInIt) { try await chat.history(for: .bob) }
        }
    }

    /// A chat's first words make its space, named after it, with the admins its platform says,
    /// and start it there; whoever writes is in both, and it stays answered by the agent it
    /// started with.
    @Test func aChatsFirstWordsMakeItsSpace() async throws {
        try await withClusterSystem("chat", store: MemoryEventStore(), hostsVirtualActors: true, people: []) { system in
            let chat = try await Conversation.resolve(
                on: system, conversationID: ConversationID(channel: ChannelID("telegram"), externalAddress: .init("42")))
            try await chat.followChat(named: SpaceName("Family")!, admins: [.ann], agent: "conversation", by: .bob)
            try await chat.followChat(named: SpaceName("Family")!, admins: [.ann, .dad], agent: "other", by: .bob)
            try await chat.admit(.cat)

            let start = try await chat.reading(by: .bob)
            #expect(start.agent == "conversation")
            #expect(try await chat.reading(by: .cat) == start)
            let space = try await Space.resolve(on: system, id: start.space)
            #expect(try await space.listing(for: .ann) == SpaceListing(id: start.space, name: SpaceName("Family")!, role: .admin))
            #expect(try await space.listing(for: .dad)?.role == .admin)
            #expect(try await space.listing(for: .bob)?.role == .member)
            #expect(try await space.listing(for: .cat)?.role == .member)
        }
    }
}
