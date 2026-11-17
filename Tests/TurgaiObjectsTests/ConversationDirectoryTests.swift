import DistributedCluster
import EventSourcing
import Testing
import TurgaiConversations
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
    /// The bot answering in these conversations.
    private let helper = ollamaBot("Helper")

    /// A person's list has the conversations they're in, each called its title once it has one;
    /// one they left is off it, and each channel's are known.
    @Test func aPersonsListFollowsTheConversationsTheyreIn() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("directory", store: store, hostsVirtualActors: true, people: []) { system in
            _ = try await system.singleton.host(ConversationDirectory.self, name: ConversationDirectory.singletonName) {
                ConversationDirectory(
                    actorSystem: $0, storage: .test, journal: store, refreshInterval: .milliseconds(10))
            }
            let family = try await madeSpace("Family", by: .ann, bot: helper, on: system)
            let space = try await Space.identified(by: family, on: system)
            func started(_ address: String) async throws -> ConversationID {
                let id = ConversationID(channel: ChannelID("turgai"), externalAddress: .init(address))
                try await space.start(id, with: nil, by: .ann)
                return id
            }
            let dinnerID = try await started("dinner")
            let tripID = try await started("trip")
            try await space.title(tripID, ConversationTitle("Trip")!, by: .ann)

            let annsList = Set([
                ConversationListing(id: dinnerID, space: family, bot: helper.id, title: nil, people: 1),
                ConversationListing(id: tripID, space: family, bot: helper.id, title: "Trip", people: 1),
            ])
            #expect(try await Set(list(of: .ann, on: system) { Set($0) == annsList }) == annsList)

            try await space.leave(dinnerID, as: .ann)
            let afterLeaving = [
                ConversationListing(id: tripID, space: family, bot: helper.id, title: "Trip", people: 1)
            ]
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
                ConversationDirectory(
                    actorSystem: $0, storage: .test, journal: store, refreshInterval: .milliseconds(10))
            }
            let notices = try await system.singleton
                .proxy(ConversationDirectory.self, name: ConversationDirectory.singletonName)
                .subscription(for: .ann)

            let family = try await madeSpace("Family", by: .ann, bot: helper, on: system)
            let space = try await Space.identified(by: family, on: system)
            let id = ConversationID(channel: ChannelID("turgai"), externalAddress: .init("dinner"))
            try await space.start(id, with: nil, by: .ann)
            try await space.title(id, ConversationTitle("Dinner")!, by: .ann)
            try await space.leave(id, as: .ann)

            var told: [ConversationNotice] = []
            for await notice in notices {
                told.append(notice)
                if case .left = notice { break }
            }
            let listed = ConversationListing(id: id, space: family, bot: helper.id, title: nil, people: 1)
            let titled = ConversationListing(id: id, space: family, bot: helper.id, title: "Dinner", people: 1)
            #expect(told.first == .joined(listed))
            #expect(told.contains(.titled(titled)))
            #expect(told.last == .left(id))
        }
    }

    /// A conversation its only person deletes is off their list, and they're told; one with others
    /// in it only someone its space lets delete anyone's deletes.
    @Test func aDeletedConversationIsOffTheList() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("deleting", store: store, hostsVirtualActors: true, people: []) { system in
            _ = try await system.singleton.host(ConversationDirectory.self, name: ConversationDirectory.singletonName) {
                ConversationDirectory(
                    actorSystem: $0, storage: .test, journal: store, refreshInterval: .milliseconds(10))
            }
            let notices = try await system.singleton
                .proxy(ConversationDirectory.self, name: ConversationDirectory.singletonName)
                .subscription(for: .ann)

            let family = try await madeSpace("Family", by: .ann, joinedBy: [.bob], bot: helper, on: system)
            let space = try await Space.identified(by: family, on: system)
            let id = ConversationID(channel: ChannelID("turgai"), externalAddress: .init("dinner"))
            try await space.start(id, with: nil, by: .bob)
            try await space.add(.person(.ann), to: id, by: .bob)
            await #expect(throws: ConversationRefusal.othersAreInIt) { try await space.delete(id, by: .bob) }
            try await space.delete(id, by: .ann)

            for await notice in notices where notice == .deleted(id) { break }
            #expect(try await list(of: .ann, on: system) { $0.isEmpty }.isEmpty)
            #expect(try await list(of: .bob, on: system) { $0.isEmpty }.isEmpty)
        }
    }

    /// Each thing said in a conversation puts it first on its people's lists, and the first line
    /// a person said there calls it, until it has a title.
    @Test func whatsSaidPutsAConversationFirst() async throws {
        let directory = ConversationDirectoryStorage.test
        let space = SpaceID()
        let a = BotID()
        let dinner = ConversationID(channel: ChannelID("turgai"), externalAddress: .init("dinner"))
        let trip = ConversationID(channel: ChannelID("turgai"), externalAddress: .init("trip"))
        func said(_ text: String, in conversation: ConversationID) -> ConversationDirectoryChange? {
            let message = InboundMessage(
                conversationID: conversation, participantID: ParticipantID("ann"), userID: .ann, text: text,
                receivedAt: Date())
            return ConversationDirectoryChange(
                .inbox(.turnStarted(PendingConversationMessage(message: message, turnID: TurnID(), bot: a))),
                in: conversation, of: space)
        }
        let changes: [ConversationDirectoryChange?] = [
            .started(dinner, in: space), .joined(dinner, .bot(a)), .joined(dinner, .person(.ann)),
            .started(trip, in: space), .joined(trip, .bot(a)), .joined(trip, .person(.ann)),
            said("\n  plan dinner  \nfor four", in: dinner), said("pasta?", in: dinner),
        ]
        for (index, change) in changes.enumerated() { try await directory.keep(change, Offset(Int64(index + 1))) }
        #expect(
            try await directory.conversations(.ann) == [
                ConversationListing(id: dinner, space: space, bot: a, title: "plan dinner", people: 1),
                ConversationListing(id: trip, space: space, bot: a, title: nil, people: 1),
            ])

        try await directory.keep(.said(trip, firstLine: nil), Offset(9))
        try await directory.keep(.titled(dinner, ConversationTitle("Dinner")!), Offset(10))
        #expect(
            try await directory.conversations(.ann) == [
                ConversationListing(id: trip, space: space, bot: a, title: nil, people: 1),
                ConversationListing(id: dinner, space: space, bot: a, title: "Dinner", people: 1),
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
