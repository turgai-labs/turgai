import EventSourcing
import Foundation
import Testing
import TurgaiDomain
import TurgaiMemory
import TurgaiPeople

@testable import TurgaiApplication

/// What's unread for a person's memory, kept from their memory events: each of their conversations
/// with an exchange not read yet, its latest, until a pass reads through it.
struct UnreadMemoryTests {
    private let ann = UserID.account(UUID())
    private let check = ConversationID(stableKey: "turgai:check")!
    private let skylark = ConversationID(stableKey: "turgai:skylark")!

    private func exchange(in conversation: ConversationID, at seconds: TimeInterval) -> MemoryObservation {
        MemoryObservation(
            sourceID: MemorySourceID(), conversation: conversation, heardBy: AgentProfileID("turgai"),
            channelMessageID: ChannelMessageID(rawValue: "42"), text: "Haar",
            observedAt: Date(timeIntervalSince1970: seconds))
    }

    private func read(_ conversation: ConversationID, through exchange: MemoryObservation) -> UserEvent {
        .memory(
            .extractionCommitted(
                MemoryExtractionCommit(
                    generation: .initial, conversation: conversation, readThrough: exchange.sourceID, changes: [])))
    }

    /// An exchange is its conversation's latest, read when its person has been quiet after it; a
    /// read names how far; forgetting everything forgets what's unread; the rest changes nothing.
    @Test
    func eachMemoryEventChangesWhatsUnread() {
        let haar = exchange(in: check, at: 1_000)
        let unread = UnreadConversation(
            person: ann, conversation: check, latest: haar.sourceID, channelMessageID: ChannelMessageID(rawValue: "42"),
            heardBy: AgentProfileID("turgai"), saidAt: Date(timeIntervalSince1970: 1_000))

        #expect(UnreadMemoryChange(.memory(.observationRecorded(haar)), of: ann) == .said(unread))
        #expect(unread.due(after: .seconds(240)) == Date(timeIntervalSince1970: 1_240))
        #expect(UnreadMemoryChange(read(check, through: haar), of: ann) == .read(ann, check, through: haar.sourceID))
        #expect(UnreadMemoryChange(.memory(.cleared(at: Date())), of: ann) == .forgotten(ann))
        #expect(UnreadMemoryChange(.memory(.factForgotten(MemoryFactID())), of: ann) == nil)
        #expect(UnreadMemoryChange(.memory(.rememberingChanged(.off)), of: ann) == nil)
    }

    /// A conversation stays unread until it's read through its latest exchange: one said while it
    /// was read keeps it; others' conversations are their own; forgetting takes all of a person's.
    @Test
    func aConversationIsUnreadUntilReadThroughItsLatest() async throws {
        let storage = UnreadMemoryStorage.test
        let first = exchange(in: check, at: 1)
        let second = exchange(in: check, at: 2)
        let tatar = exchange(in: skylark, at: 3)
        var offset: Int64 = 0
        func keep(_ event: UserEvent) async throws {
            offset += 1
            try await storage.keep(UnreadMemoryChange(event, of: ann), Offset(offset))
        }

        try await keep(.memory(.observationRecorded(first)))
        try await keep(.memory(.observationRecorded(second)))
        try await keep(.memory(.observationRecorded(tatar)))
        try await keep(read(check, through: first))
        #expect(Set(try await storage.unread().map(\.latest)) == [second.sourceID, tatar.sourceID])

        try await keep(read(check, through: second))
        try await keep(read(check, through: second))
        #expect(try await storage.unread().map(\.latest) == [tatar.sourceID])
        #expect(try await storage.offset() == Offset(6))

        try await keep(.memory(.cleared(at: Date())))
        #expect(try await storage.unread().isEmpty)
    }

    /// A person's journal names them; another's names no one.
    @Test
    func aPersonsJournalNamesThem() {
        #expect(User.userID(persistenceID: User.persistenceID(for: ann)) == ann)
        #expect(User.userID(persistenceID: "turgai-conversation-turgai:check") == nil)
    }
}
