import EventSourcing
import Testing
import TurgaiDomain
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct FilePersistenceClientTests {
    private enum TestEvent: Codable, Equatable, Sendable {
        case started(String)
        case finished
    }

    @Test
    func discoversAndReadsJournalThroughClient() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turgai-file-persistence-" + UUID().uuidString)
        let journalDirectory = directory.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )
        let event = EventEnvelope(
            persistenceID: "conversation-one",
            sequenceNumber: 1,
            event: TestEvent.started("one")
        )
        var encodedEvent = try JSONEncoder().encode(event)
        encodedEvent.append(0x0A)
        try encodedEvent.write(
            to: journalDirectory.appendingPathComponent("conversation-one.jsonl")
        )
        let persistence = try FilePersistenceClient(directory: directory)

        #expect(
            try persistence.persistenceIDs(withPrefix: "conversation-")
                == ["conversation-one"]
        )
        #expect(
            try await persistence.events(for: "conversation-one")
                == [TestEvent.started("one")]
        )
    }

    @Test
    func conversationJournalReaderReadsOnlyConversationJournals() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turgai-conversation-journals-" + UUID().uuidString)
        let persistence = try FilePersistenceClient(directory: directory)
        let conversationID = ConversationID(
            channel: ChannelID("telegram"),
            externalAddress: ExternalConversationAddress("42")
        )
        let message = InboundMessage(
            conversationID: conversationID,
            participantID: ParticipantID(channel: ChannelID("telegram"), rawValue: "7"),
            text: "hello",
            receivedAt: Date(timeIntervalSince1970: 1)
        )
        let persistenceID = "turgai-conversation-\(conversationID.stableKey)"
        let envelope = EventEnvelope(
            persistenceID: persistenceID,
            sequenceNumber: 1,
            event: ConversationEvent.messageQueued(
                PendingConversationMessage(message: message, turnID: TurnID())
            )
        )
        var data = try JSONEncoder().encode(envelope)
        data.append(0x0A)
        try data.write(
            to:
                directory
                .appendingPathComponent("journal", isDirectory: true)
                .appendingPathComponent("turgai-conversation-telegram_42.jsonl")
        )

        let reader = ConversationJournalReader(
            client: persistence
        )
        let journals = try await reader.conversationJournals()

        #expect(journals.count == 1)
        #expect(journals.first?.conversationID == conversationID)
        #expect(journals.first?.events.count == 1)
    }
}
