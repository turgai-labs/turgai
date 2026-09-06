import EventSourcing
import Foundation
@testable import NorbyPersistence
import Testing

struct FileEventStoreTests {
  private enum TestEvent: Codable, Equatable, Sendable {
    case started(String)
    case finished
  }

  @Test
  func persistsAndStreamsEventsInSequenceOrder() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("norby-file-event-store-" + UUID().uuidString)
    let store = FileEventStore(
      client: try FilePersistenceClient(directory: directory)
    )

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
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("norby-file-event-store-" + UUID().uuidString)
    let store = FileEventStore(
      client: try FilePersistenceClient(directory: directory)
    )

    try await store.persistEvent(TestEvent.finished, id: "agent/two", sequenceNumber: 1)

    await #expect(throws: (any Error).self) {
      try await store.persistEvent(TestEvent.finished, id: "agent/two", sequenceNumber: 1)
    }
  }

  @Test
  func missingJournalStreamsAsEmpty() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("norby-file-event-store-" + UUID().uuidString)
    let store = FileEventStore(
      client: try FilePersistenceClient(directory: directory)
    )

    let events: [TestEvent] = try await store.eventsFor(id: "missing")

    #expect(events.isEmpty)
  }

}
