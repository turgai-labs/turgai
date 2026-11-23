import AttributedCalls
import Testing
import TurgaiCalls
import TurgaiConversations
import TurgaiDomain

@testable import TurgaiApplication
@testable import TurgaiSpaces

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A conversation starts once, in its space, answered by one of the space's bots, and is reached
/// only through its space.
@Suite
struct ConversationStartTests {
    private let helper = ollamaBot("Helper")

    /// A conversation in Turgai's apps starts in a space whoever starts it is in, answered by its
    /// main bot, and only its people read it.
    @Test func anAppsConversationStartsInASpaceItsFirstPersonIsIn() async throws {
        try await withClusterSystem("start", store: MemoryEventStore(), hostsVirtualActors: true, people: []) {
            system in
            let family = try await Space.identified(
                by: try await madeSpace("Family", by: .ann, bot: helper, on: system), on: system)
            let id = ConversationID(channel: ChannelID("turgai"), externalAddress: .init(UUID().uuidString))
            await #expect(throws: ConversationRefusal.notStarted) { try await family.history(of: id, for: .ann) }
            await #expect(throws: SpaceRefusal.notInIt) { try await family.start(id, with: nil, by: .bob) }

            try await family.start(id, with: nil, by: .ann)
            #expect(
                try await family.reading(id, by: .ann)
                    == ConversationOutline(participants: [.bot(helper.id), .person(.ann)]))
            await #expect(throws: ConversationRefusal.alreadyStarted) {
                try await family.start(id, with: helper.id, by: .ann)
            }
            let ghost = BotID()
            await #expect(throws: SpaceRefusal.noSuchBot(ghost)) {
                try await family.start(
                    ConversationID(channel: ChannelID("turgai"), externalAddress: .init(UUID().uuidString)),
                    with: ghost, by: .ann)
            }
            await #expect(throws: SpaceRefusal.notInIt) { try await family.history(of: id, for: .bob) }
        }
    }

    /// A conversation is found by its id from anywhere, and a call that reaches it from outside its
    /// space is put to the space: one that is no one's is refused before it reaches it.
    @Test func aCallThatIsNotItsSpacesDoesNotReachIt() async throws {
        try await withClusterSystem("outside", store: MemoryEventStore(), hostsVirtualActors: true, people: []) {
            system in
            let spaceID = try await madeSpace("Family", by: .ann, bot: helper, on: system)
            let family = try await Space.identified(by: spaceID, on: system)
            let id = ConversationID(channel: ChannelID("turgai"), externalAddress: .init(UUID().uuidString))
            try await family.start(id, with: nil, by: .ann)

            let conversation = try await Conversation.identified(by: id, in: spaceID, on: system)
            await #expect(throws: CallOnBehalfOfNoOne.self) {
                _ = try await conversation.currentRecord()
            }
            // Through its space, it's read as before.
            #expect(try await family.reading(id, by: .ann).participants == [.bot(helper.id), .person(.ann)])
        }
    }

    /// One of its people adds someone in its space, who then reads it; someone who isn't in the
    /// space can't be added. Its space's people are seen by those in it.
    @Test func someoneInItsSpaceIsAdded() async throws {
        try await withClusterSystem("add", store: MemoryEventStore(), hostsVirtualActors: true, people: []) { system in
            let family = try await Space.identified(
                by: try await madeSpace("Family", by: .ann, joinedBy: [.bob], bot: helper, on: system), on: system)
            let id = ConversationID(channel: ChannelID("turgai"), externalAddress: .init(UUID().uuidString))
            try await family.start(id, with: nil, by: .ann)

            await #expect(throws: SpaceRefusal.notInIt) { try await family.add(.person(.cat), to: id, by: .ann) }
            try await family.add(.person(.bob), to: id, by: .ann)
            #expect(
                try await family.reading(id, by: .bob).participants
                    == [.bot(helper.id), .person(.ann), .person(.bob)])
            #expect(try await family.people(for: .bob) == [.ann: [.members, .guests], .bob: [.members]])
            await #expect(throws: SpaceRefusal.notInIt) { try await family.people(for: .cat) }
        }
    }

    /// A message said only to people in it starts no turn: it's kept, and they read it.
    @Test func aMessageToPeopleStartsNoTurn() async throws {
        try await withClusterSystem("said", store: MemoryEventStore(), hostsVirtualActors: true, people: []) { system in
            let family = try await Space.identified(
                by: try await madeSpace("Family", by: .ann, joinedBy: [.bob], bot: helper, on: system), on: system)
            let id = ConversationID(channel: ChannelID("turgai"), externalAddress: .init(UUID().uuidString))
            try await family.start(id, with: nil, by: .ann)
            try await family.add(.person(.bob), to: id, by: .ann)

            // This node runs no agent: a turn would fail to start.
            try await family.say(
                InboundMessage(
                    conversationID: id, participantID: ParticipantID(channel: id.channel, rawValue: UserID.ann.key),
                    userID: .ann, text: "pasta tonight?", receivedAt: Date(), to: [.person(.bob)]),
                turnID: TurnID())
            #expect(try await family.history(of: id, for: .bob).map(\.text) == ["pasta tonight?"])
            #expect(try await family.status(of: id, for: .bob) == .idle)
        }
    }

    /// Someone writing in a chat of a space's connection is one of its members, and in the chat's
    /// conversation, which starts the first time, answered by the space's main bot; whoever the
    /// chat's platform says is in it is too.
    @Test func aChatsFirstWordsStartItInItsSpace() async throws {
        try await withClusterSystem("chat", store: MemoryEventStore(), hostsVirtualActors: true, people: []) { system in
            let family = try await Space.identified(
                by: try await madeSpace("Family", by: .ann, bot: helper, on: system), on: system)
            let id = ConversationID(channel: ChannelID("telegram"), externalAddress: .init("42"))
            try await family.followChat(id, by: .bob)
            try await family.followChat(id, by: .bob)
            try await family.admitToChat(.cat, in: id)

            let start = try await family.reading(id, by: .bob)
            #expect(start.bot == helper.id)
            #expect(try await family.reading(id, by: .cat) == start)
            #expect(try await family.listing(for: .ann)?.permissions == .all)
            #expect(try await family.listing(for: .bob)?.permissions == .members)
            #expect(try await family.listing(for: .cat)?.permissions == .members)
        }
    }
}
