import DistributedCluster
import EventSourcing
import Testing
import TurgaiDomain
import TurgaiSpaces

@testable import TurgaiApplication

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The conversation directory: each person's list, kept from the conversations' own events.
@Suite
struct ConversationDirectoryTests {
    /// A person's list has the conversations they're in, each called its title once it has one;
    /// one they left is off it, and each channel's are known.
    @Test func aPersonsListFollowsTheConversationsTheyreIn() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("directory", store: store, hostsVirtualActors: true, people: []) { system in
            _ = try await system.singleton.host(ConversationDirectory.self, name: ConversationDirectory.singletonName) {
                ConversationDirectory(actorSystem: $0, storage: .test, journal: store, refreshInterval: .milliseconds(10))
            }
            let family = try await Spaces(actorSystem: system).make(named: SpaceName("Family")!, by: .ann)
            func started(_ address: String) async throws -> (ConversationID, Conversation) {
                let id = ConversationID(channel: ChannelID("turgai"), externalAddress: .init(address))
                let conversation = try await Conversation.resolve(on: system, conversationID: id)
                try await conversation.start(in: family.id, agent: AgentProfileID("conversation"), by: .ann)
                return (id, conversation)
            }
            let (dinnerID, dinner) = try await started("dinner")
            let (tripID, trip) = try await started("trip")
            try await trip.title(ConversationTitle("Trip")!, by: .ann)

            let annsList = Set([
                ConversationListing(id: dinnerID, space: family.id, agent: AgentProfileID("conversation"), title: nil),
                ConversationListing(id: tripID, space: family.id, agent: AgentProfileID("conversation"), title: "Trip"),
            ])
            #expect(try await Set(list(of: .ann, on: system) { Set($0) == annsList }) == annsList)

            try await dinner.leave(.ann)
            let afterLeaving = [ConversationListing(id: tripID, space: family.id, agent: AgentProfileID("conversation"), title: "Trip")]
            #expect(try await list(of: .ann, on: system) { $0 == afterLeaving } == afterLeaving)

            let onTurgai = try await system.singleton
                .proxy(ConversationDirectory.self, name: ConversationDirectory.singletonName)
                .conversations(on: ChannelID("turgai"))
            #expect(Set(onTurgai) == [dinnerID, tripID])
        }
    }

    /// Someone following their conversations is told as they join one, as it changes, and as they
    /// leave it.
    @Test func aPersonIsToldAboutTheirConversations() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("notices", store: store, hostsVirtualActors: true, people: []) { system in
            _ = try await system.singleton.host(ConversationDirectory.self, name: ConversationDirectory.singletonName) {
                ConversationDirectory(actorSystem: $0, storage: .test, journal: store, refreshInterval: .milliseconds(10))
            }
            let (notices, telling) = AsyncStream<ConversationNotice>.makeStream()
            let listener = ConversationNoticeListener(actorSystem: system) { telling.yield($0) }
            try await system.singleton.proxy(ConversationDirectory.self, name: ConversationDirectory.singletonName)
                .follow(.ann, with: listener)

            let family = try await Spaces(actorSystem: system).make(named: SpaceName("Family")!, by: .ann)
            let id = ConversationID(channel: ChannelID("turgai"), externalAddress: .init("dinner"))
            let dinner = try await Conversation.resolve(on: system, conversationID: id)
            try await dinner.start(in: family.id, agent: AgentProfileID("conversation"), by: .ann)
            try await dinner.title(ConversationTitle("Dinner")!, by: .ann)
            try await dinner.leave(.ann)

            var told: [ConversationNotice] = []
            for await notice in notices {
                told.append(notice)
                if case .left = notice { break }
            }
            let listed = ConversationListing(id: id, space: family.id, agent: AgentProfileID("conversation"), title: nil)
            let titled = ConversationListing(id: id, space: family.id, agent: AgentProfileID("conversation"), title: "Dinner")
            #expect(told.first == .joined(listed))
            #expect(told.contains(.titled(titled)))
            #expect(told.last == .left(id))
        }
    }

    /// Each thing said in a conversation puts it first on its people's lists, and the first line
    /// a person said there calls it, until it has a title.
    @Test func whatsSaidPutsAConversationFirst() async throws {
        let directory = ConversationDirectoryStorage.test
        let space = SpaceID()
        let a = AgentProfileID("a")
        let dinner = ConversationID(channel: ChannelID("turgai"), externalAddress: .init("dinner"))
        let trip = ConversationID(channel: ChannelID("turgai"), externalAddress: .init("trip"))
        func said(_ text: String, in conversation: ConversationID) -> ConversationDirectoryChange? {
            let message = InboundMessage(
                conversationID: conversation, participantID: ParticipantID("ann"), userID: .ann, text: text,
                receivedAt: Date())
            return ConversationDirectoryChange(
                .inbox(.turnStarted(PendingConversationMessage(message: message, turnID: TurnID(), agentRole: "a"))),
                in: conversation)
        }
        let changes: [ConversationDirectoryChange?] = [
            .started(dinner, in: space), .joined(dinner, .agent(a)), .joined(dinner, .person(.ann)),
            .started(trip, in: space), .joined(trip, .agent(a)), .joined(trip, .person(.ann)),
            said("\n  plan dinner  \nfor four", in: dinner), said("pasta?", in: dinner),
        ]
        for (index, change) in changes.enumerated() { try await directory.keep(change, Offset(Int64(index + 1))) }
        #expect(
            try await directory.conversations(.ann) == [
                ConversationListing(id: dinner, space: space, agent: a, title: "plan dinner"),
                ConversationListing(id: trip, space: space, agent: a, title: nil),
            ])

        try await directory.keep(.said(trip, firstLine: nil), Offset(9))
        try await directory.keep(.titled(dinner, ConversationTitle("Dinner")!), Offset(10))
        #expect(
            try await directory.conversations(.ann) == [
                ConversationListing(id: trip, space: space, agent: a, title: nil),
                ConversationListing(id: dinner, space: space, agent: a, title: "Dinner"),
            ])
    }

    /// `person`'s list once it's `expected`, or as it is after two seconds: the directory follows
    /// the conversations a moment behind.
    private func list(
        of person: UserID, on system: ClusterSystem, once expected: ([ConversationListing]) -> Bool
    ) async throws -> [ConversationListing] {
        let directory = try await system.singleton.proxy(
            ConversationDirectory.self, name: ConversationDirectory.singletonName)
        var listed = try await directory.conversations(of: person)
        for _ in 0..<200 where !expected(listed) {
            try await Task.sleep(for: .milliseconds(10))
            listed = try await directory.conversations(of: person)
        }
        return listed
    }
}
