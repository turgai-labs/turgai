import DiscoverableActors
import DistributedCluster
import Foundation

/// The user's calendars and their events.
@Discoverable
public distributed actor Calendar {
    public typealias ActorSystem = ClusterSystem

    private let client: CalendarClient
    private var known: [CalendarID: EventCalendar] = [:]

    public init(actorSystem: ActorSystem, client: CalendarClient) async throws {
        self.actorSystem = actorSystem
        self.client = client
        let object = try DiscoverableObject.resolve(id: self.id, using: actorSystem)
        await actorSystem.receptionist.checkIn(object, with: .objects)
    }

    /// The calendars available in the user's account.
    @DiscoverableAction(safe: true, idempotent: true)
    public distributed func calendars() async throws -> [EventCalendar] {
        let records = try await client.calendars()
        var calendars: [EventCalendar] = []
        for record in records {
            if let calendar = known[record.id] {
                try await calendar.refresh(record)
                calendars.append(calendar)
                continue
            }
            let calendar = EventCalendar(actorSystem: actorSystem, client: client, record: record)
            known[record.id] = calendar
            calendars.append(calendar)
        }
        return calendars
    }
}

/// One calendar.
@Discoverable
public distributed actor EventCalendar {
    public typealias ActorSystem = ClusterSystem

    private let client: CalendarClient
    private var record: EventCalendarRecord
    private var known: [CalendarEventID: CalendarEvent] = [:]

    init(actorSystem: ActorSystem, client: CalendarClient, record: EventCalendarRecord) {
        self.actorSystem = actorSystem
        self.client = client
        self.record = record
    }

    public distributed var title: String { record.title }

    /// Events between two dates. The end date is exclusive.
    @DiscoverableAction(safe: true, idempotent: true)
    public distributed func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let records = try await client.events(record.id, start, end)
        var events: [CalendarEvent] = []
        for event in records {
            if let known = known[event.id] {
                try await known.refresh(event)
                events.append(known)
                continue
            }
            let object = CalendarEvent(actorSystem: actorSystem, client: client, record: event)
            known[event.id] = object
            events.append(object)
        }
        return events
    }

    /// Create an event in this calendar.
    public distributed func add(title: String, from start: Date, to end: Date, notes: String? = nil) async throws
        -> CalendarEvent
    {
        let event = try await client.add(record.id, title, start, end, notes)
        let object = CalendarEvent(actorSystem: actorSystem, client: client, record: event)
        known[event.id] = object
        return object
    }

    distributed func refresh(_ record: EventCalendarRecord) { self.record = record }
}

/// One event; properties reflect the last listing or change.
@Discoverable
public distributed actor CalendarEvent {
    public typealias ActorSystem = ClusterSystem

    private let client: CalendarClient
    private var record: CalendarEventRecord

    init(actorSystem: ActorSystem, client: CalendarClient, record: CalendarEventRecord) {
        self.actorSystem = actorSystem
        self.client = client
        self.record = record
    }

    public distributed var title: String { record.title }
    public distributed var start: Date { record.start }
    public distributed var end: Date { record.end }
    public distributed var location: String? { record.location }
    public distributed var notes: String? { record.notes }

    /// Remove this event from the calendar.
    public distributed func delete() async throws { try await client.delete(record.id) }

    distributed func refresh(_ record: CalendarEventRecord) { self.record = record }
}

public struct CalendarClient: Sendable {
    public var calendars: @Sendable () async throws -> [EventCalendarRecord]
    public var events: @Sendable (CalendarID, Date, Date) async throws -> [CalendarEventRecord]
    public var add: @Sendable (CalendarID, String, Date, Date, String?) async throws -> CalendarEventRecord
    public var delete: @Sendable (CalendarEventID) async throws -> Void

    public init(
        calendars: @escaping @Sendable () async throws -> [EventCalendarRecord],
        events: @escaping @Sendable (CalendarID, Date, Date) async throws -> [CalendarEventRecord],
        add: @escaping @Sendable (CalendarID, String, Date, Date, String?) async throws -> CalendarEventRecord,
        delete: @escaping @Sendable (CalendarEventID) async throws -> Void
    ) {
        self.calendars = calendars
        self.events = events
        self.add = add
        self.delete = delete
    }
}

public struct CalendarID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct CalendarEventID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct EventCalendarRecord: Codable, Sendable, Equatable {
    public var id: CalendarID
    public var title: String
    public init(id: CalendarID, title: String) {
        self.id = id
        self.title = title
    }
}

public struct CalendarEventRecord: Codable, Sendable, Equatable {
    public var id: CalendarEventID
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String?
    public var notes: String?
    public init(
        id: CalendarEventID, title: String, start: Date, end: Date, location: String? = nil, notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
    }
}
