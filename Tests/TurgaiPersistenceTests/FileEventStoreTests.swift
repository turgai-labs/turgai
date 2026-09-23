import EventSourcing
import Testing
import TurgaiDomain
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct FileEventStoreTests {
    private enum TestEvent: Codable, Equatable, Sendable {
        case started(String)
        case finished
    }

    @Test
    func persistsAndStreamsEventsInSequenceOrder() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileEventStore(client: try FileClient(directory: directory))

        try await store.persistEvent(TestEvent.started("hello"), id: "agent/one", sequenceNumber: 1)
        try await store.persistEvent(TestEvent.finished, id: "agent/one", sequenceNumber: 2)

        let stream: EventStream<TestEvent> = try await store.eventStream(
            id: "agent/one",
            fromSequenceNumber: 2
        )
        var envelopes: [EventEnvelope<TestEvent>] = []
        for try await envelope in stream {
            envelopes.append(envelope)
        }

        #expect(envelopes.count == 1)
        #expect(envelopes.first?.sequenceNumber == 2)
        #expect(envelopes.first?.event == .finished)
    }

    @Test
    func rejectsDuplicateSequenceNumbers() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileEventStore(client: try FileClient(directory: directory))

        try await store.persistEvent(TestEvent.finished, id: "agent/two", sequenceNumber: 1)

        await #expect(throws: (any Error).self) {
            try await store.persistEvent(TestEvent.finished, id: "agent/two", sequenceNumber: 1)
        }
    }

    @Test
    func missingJournalStreamsAsEmpty() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileEventStore(client: try FileClient(directory: directory))

        let events: [TestEvent] = try await store.eventsFor(id: "missing")

        #expect(events.isEmpty)
    }

    @Test
    func discoversAndReadsPersistedJournals() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A journal written by an earlier process, with the store's layout.
        let journalDirectory = directory.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )
        let envelope = EventEnvelope(
            persistenceID: "conversation-one",
            sequenceNumber: 1,
            event: TestEvent.started("one")
        )
        var encoded = try JSONEncoder().encode(envelope)
        encoded.append(0x0A)
        try encoded.write(
            to: journalDirectory.appendingPathComponent("conversation-one.jsonl")
        )

        let store = FileEventStore(client: try FileClient(directory: directory))

        let reader = FileJournalReader(client: try FileClient(directory: directory))
        #expect(try await reader.persistenceIDs(withPrefix: "conversation-") == ["conversation-one"])
        let events: [TestEvent] = try await store.eventsFor(id: "conversation-one")
        #expect(events == [.started("one")])
    }

    @Test
    func startupRecoveryReadsOnlyConversationJournals() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

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
                PendingConversationMessage(
                    message: message,
                    turnID: TurnID(),
                    agentRole: "test"
                )
            )
        )
        var data = try JSONEncoder().encode(envelope)
        data.append(0x0A)
        let journalDirectory = directory.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )
        try data.write(
            to: journalDirectory.appendingPathComponent("turgai-conversation-telegram_42.jsonl")
        )

        let store = FileEventStore(client: try FileClient(directory: directory))
        let reader = FileJournalReader(client: try FileClient(directory: directory))
        let persistenceIDs = try await reader.persistenceIDs(withPrefix: ConversationPersistenceID.prefix)
        let recoveredIDs = persistenceIDs.compactMap {
            ConversationPersistenceID(rawValue: $0)?.conversationID
        }

        #expect(recoveredIDs == [conversationID])
        let events: [ConversationEvent] = try await store.eventsFor(id: persistenceID)
        #expect(events.count == 1)
    }

    private func makeDirectory() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("turgai-file-event-store-\(UUID().uuidString)", isDirectory: true)
    }
}
