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
    private let conversation = AgentProfileID("conversation")

    /// A conversation in Turgai's apps starts in a space whoever starts it is in, and only its
    /// people read it.
    @Test func anAppsConversationStartsInASpaceItsFirstPersonIsIn() async throws {
        try await withClusterSystem("start", store: MemoryEventStore(), hostsVirtualActors: true, people: []) {
            system in
            let family = try await Spaces(actorSystem: system, turgaisOwn: SpaceID()).make(
                named: SpaceName("Family")!, by: .ann)
            let chat = try await Conversation.resolve(
                on: system,
                conversationID: ConversationID(channel: ChannelID("turgai"), externalAddress: .init(UUID().uuidString)))
            await #expect(throws: ConversationRefusal.notStarted) { try await chat.history(for: .ann) }
            await #expect(throws: SpaceRefusal.notInIt) {
                try await chat.start(in: family.id, agent: conversation, by: .bob)
            }

            try await chat.start(in: family.id, agent: conversation, by: .ann)
            #expect(
                try await chat.reading(by: .ann)
                    == ConversationOutline(space: family.id, participants: [.agent(conversation), .person(.ann)]))
            await #expect(throws: ConversationRefusal.alreadyStarted) {
                try await chat.start(in: family.id, agent: AgentProfileID("other"), by: .ann)
            }
            await #expect(throws: ConversationRefusal.notInIt) { try await chat.history(for: .bob) }
        }
    }

    /// One of its people adds someone in its space, who then reads it; someone who isn't in the
    /// space can't be added. Its space's people are seen by those in it.
    @Test func someoneInItsSpaceIsAdded() async throws {
        try await withClusterSystem("add", store: MemoryEventStore(), hostsVirtualActors: true, people: []) { system in
            let spaces = Spaces(actorSystem: system, turgaisOwn: SpaceID())
            let family = try await spaces.make(named: SpaceName("Family")!, by: .ann)
            let (_, token) = try await spaces.invite(to: family.id, by: .ann, for: .untilUsed)
            _ = try await spaces.join(family.id, with: token, as: .bob)
            let chat = try await Conversation.resolve(
                on: system,
                conversationID: ConversationID(channel: ChannelID("turgai"), externalAddress: .init(UUID().uuidString)))
            try await chat.start(in: family.id, agent: conversation, by: .ann)

            await #expect(throws: SpaceRefusal.notInIt) { try await chat.add(.person(.cat), by: .ann) }
            try await chat.add(.person(.bob), by: .ann)
            #expect(
                try await chat.reading(by: .bob).participants == [.agent(conversation), .person(.ann), .person(.bob)])
            #expect(try await spaces.people(in: family.id, for: .bob) == [.ann: .admin, .bob: .member])
            await #expect(throws: SpaceRefusal.notInIt) { try await spaces.people(in: family.id, for: .cat) }
        }
    }

    /// A message said only to people in it starts no turn: it's kept, and they read it.
    @Test func aMessageToPeopleStartsNoTurn() async throws {
        try await withClusterSystem("said", store: MemoryEventStore(), hostsVirtualActors: true, people: []) { system in
            let spaces = Spaces(actorSystem: system, turgaisOwn: SpaceID())
            let family = try await spaces.make(named: SpaceName("Family")!, by: .ann)
            let (_, token) = try await spaces.invite(to: family.id, by: .ann, for: .untilUsed)
            _ = try await spaces.join(family.id, with: token, as: .bob)
            let id = ConversationID(channel: ChannelID("turgai"), externalAddress: .init(UUID().uuidString))
            let chat = try await Conversation.resolve(on: system, conversationID: id)
            try await chat.start(in: family.id, agent: conversation, by: .ann)
            try await chat.add(.person(.bob), by: .ann)

            // This node runs no agent: a turn would fail to start.
            try await chat.send(
                InboundMessage(
                    conversationID: id, participantID: ParticipantID(channel: id.channel, rawValue: UserID.ann.key),
                    userID: .ann, text: "pasta tonight?", receivedAt: Date(), to: [.person(.bob)]),
                turnID: TurnID(), configuration: Conversation.TurnConfiguration(agentModel: nil))
            #expect(try await chat.history(for: .bob).map(\.text) == ["pasta tonight?"])
            #expect(try await chat.status(for: .bob) == .idle)
        }
    }

    /// A chat's first words make its space, named after it, with the admins its platform says,
    /// and start it there; whoever writes is in both, and it stays answered by the agent it
    /// started with.
    @Test func aChatsFirstWordsMakeItsSpace() async throws {
        try await withClusterSystem("chat", store: MemoryEventStore(), hostsVirtualActors: true, people: []) { system in
            let chat = try await Conversation.resolve(
                on: system, conversationID: ConversationID(channel: ChannelID("telegram"), externalAddress: .init("42")))
            try await chat.followChat(named: SpaceName("Family")!, admins: [.ann], agent: conversation, by: .bob)
            try await chat.followChat(
                named: SpaceName("Family")!, admins: [.ann, .dad], agent: AgentProfileID("other"), by: .bob)
            try await chat.admit(.cat)

            let start = try await chat.reading(by: .bob)
            #expect(start.agent == conversation)
            #expect(try await chat.reading(by: .cat) == start)
            let space = try await Space.resolve(on: system, id: start.space)
            #expect(
                try await space.listing(for: .ann)
                    == SpaceListing(id: start.space, name: SpaceName("Family")!, role: .admin, status: .active))
            #expect(try await space.listing(for: .dad)?.role == .admin)
            #expect(try await space.listing(for: .bob)?.role == .member)
            #expect(try await space.listing(for: .cat)?.role == .member)
        }
    }
}
