import EventKit
import Foundation

extension CalendarClient {
    public static let live: CalendarClient = {
        let events = CalendarEventStore()
        @Sendable func calendar(_ id: CalendarID, in store: EKEventStore) throws -> EKCalendar {
            guard let calendar = store.calendar(withIdentifier: id.rawValue) else {
                throw CalendarError.unknownCalendar(id)
            }
            return calendar
        }
        @Sendable func event(_ id: CalendarEventID, in store: EKEventStore) throws -> EKEvent {
            guard let event = store.calendarItem(withIdentifier: id.rawValue) as? EKEvent else {
                throw CalendarError.unknownEvent(id)
            }
            return event
        }
        @Sendable func record(_ event: EKEvent) -> CalendarEventRecord {
            CalendarEventRecord(
                id: CalendarEventID(rawValue: event.eventIdentifier ?? event.calendarItemIdentifier),
                title: event.title ?? "",
                start: event.startDate,
                end: event.endDate,
                location: event.location,
                notes: event.notes
            )
        }
        return CalendarClient(
            calendars: {
                try await events.run { store in
                    store.store.calendars(for: .event).map {
                        EventCalendarRecord(id: CalendarID(rawValue: $0.calendarIdentifier), title: $0.title)
                    }
                }
            },
            events: { id, start, end in
                try await events.run { store in
                    let selected = try calendar(id, in: store.store)
                    let predicate = store.store.predicateForEvents(withStart: start, end: end, calendars: [selected])
                    return store.store.events(matching: predicate).map(record)
                }
            },
            add: { id, title, start, end, notes in
                try await events.run { store in
                    let event = EKEvent(eventStore: store.store)
                    event.calendar = try calendar(id, in: store.store)
                    event.title = title
                    event.startDate = start
                    event.endDate = end
                    event.notes = notes
                    try store.store.save(event, span: .thisEvent, commit: true)
                    return record(event)
                }
            },
            delete: { id in
                try await events.run { store in
                    try store.store.remove(event(id, in: store.store), span: .thisEvent, commit: true)
                }
            }
        )
    }()
}

private actor CalendarEventStore {
    let store = EKEventStore()

    func run<Value: Sendable>(
        _ body: @Sendable (isolated CalendarEventStore) async throws -> Value
    ) async throws -> Value {
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            guard try await store.requestFullAccessToEvents() else { throw CalendarError.accessDenied }
        }
        return try await body(self)
    }
}

public enum CalendarError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case accessDenied
    case unknownCalendar(CalendarID)
    case unknownEvent(CalendarEventID)

    public var description: String {
        switch self {
        case .accessDenied:
            "Turgai isn't allowed to use Calendar. Allow it in System Settings › Privacy & Security › Calendars."
        case .unknownCalendar(let id): "There's no calendar \(id.rawValue) any more."
        case .unknownEvent(let id): "There's no calendar event \(id.rawValue) any more."
        }
    }
}
