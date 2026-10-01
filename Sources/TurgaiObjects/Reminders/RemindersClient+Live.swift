import EventKit
import Foundation

extension RemindersClient {
    /// Reminders from the Reminders app, through EventKit.
    ///
    /// Asks for access on first use, which shows a permission prompt, and throws
    /// ``ReminderError/accessDenied`` if it's refused.
    /// A command-line process is asked on behalf of the terminal it runs in; an
    /// app bundle needs `NSRemindersFullAccessUsageDescription` in its Info.plist.
    public static let live: RemindersClient = {
        let events = EventStore()

        @Sendable func calendar(_ id: ReminderListID, in store: EKEventStore) throws -> EKCalendar {
            guard let calendar = store.calendar(withIdentifier: id.rawValue) else {
                throw ReminderError.unknownList(id)
            }
            return calendar
        }

        @Sendable func reminder(_ id: ReminderID, in store: EKEventStore) throws -> EKReminder {
            guard let reminder = store.calendarItem(withIdentifier: id.rawValue) as? EKReminder else {
                throw ReminderError.unknownReminder(id)
            }
            return reminder
        }

        @Sendable func record(_ reminder: EKReminder) -> ReminderRecord {
            ReminderRecord(
                id: ReminderID(rawValue: reminder.calendarItemIdentifier),
                list: ReminderListID(rawValue: reminder.calendar?.calendarIdentifier ?? ""),
                title: reminder.title ?? "",
                notes: reminder.notes,
                due: reminder.dueDateComponents.flatMap { Foundation.Calendar.current.date(from: $0) },
                isCompleted: reminder.isCompleted
            )
        }

        @Sendable func components(_ date: Date) -> DateComponents {
            Foundation.Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .timeZone], from: date)
        }

        return RemindersClient(
            lists: {
                try await events.run { events in
                    events.store.calendars(for: .reminder).map {
                        ReminderListRecord(id: ReminderListID(rawValue: $0.calendarIdentifier), title: $0.title)
                    }
                }
            },
            defaultList: {
                try await events.run { events in
                    guard let calendar = events.store.defaultCalendarForNewReminders() else {
                        throw ReminderError.noDefaultList
                    }
                    return ReminderListRecord(
                        id: ReminderListID(rawValue: calendar.calendarIdentifier), title: calendar.title)
                }
            },
            reminders: { list, includeCompleted in
                try await events.run { events in
                    let store = events.store
                    let calendars = [try calendar(list, in: store)]
                    let predicate =
                        includeCompleted
                        ? store.predicateForReminders(in: calendars)
                        : store.predicateForIncompleteReminders(
                            withDueDateStarting: nil, ending: nil, calendars: calendars)
                    return await withCheckedContinuation { continuation in
                        store.fetchReminders(matching: predicate) { reminders in
                            continuation.resume(returning: (reminders ?? []).map(record))
                        }
                    }
                }
            },
            add: { title, notes, due, list in
                try await events.run { events in
                    let store = events.store
                    let reminder = EKReminder(eventStore: store)
                    reminder.calendar = try calendar(list, in: store)
                    reminder.title = title
                    reminder.notes = notes
                    reminder.dueDateComponents = due.map(components)
                    try store.save(reminder, commit: true)
                    return record(reminder)
                }
            },
            setCompleted: { id, isCompleted in
                try await events.run { events in
                    let store = events.store
                    let reminder = try reminder(id, in: store)
                    reminder.isCompleted = isCompleted
                    try store.save(reminder, commit: true)
                    return record(reminder)
                }
            },
            reschedule: { id, due in
                try await events.run { events in
                    let store = events.store
                    let reminder = try reminder(id, in: store)
                    reminder.dueDateComponents = due.map(components)
                    try store.save(reminder, commit: true)
                    return record(reminder)
                }
            }
        )
    }()
}

/// Owns the event store, which isn't Sendable, and runs work against it one piece at a time.
private actor EventStore {
    let store = EKEventStore()

    /// Runs `body` once the user has allowed full access to reminders.
    func run<Result: Sendable>(
        _ body: @Sendable (isolated EventStore) async throws -> Result
    ) async throws -> Result {
        if EKEventStore.authorizationStatus(for: .reminder) != .fullAccess {
            guard try await self.store.requestFullAccessToReminders() else { throw ReminderError.accessDenied }
        }
        return try await body(self)
    }
}
