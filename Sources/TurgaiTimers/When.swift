import DiscoverableActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// When something's due again and again: every so many minutes, every day at a time, or on days
/// of the week at a time, in an IANA time zone.
@Describable
public enum Schedule: Codable, Sendable, Equatable {
    /// Every so many minutes.
    case every(minutes: Int)
    /// Every day at a time.
    case daily(hour: Int, minute: Int, timeZone: String)
    /// On days of the week at a time.
    case weekly(weekdays: [Weekday], hour: Int, minute: Int, timeZone: String)

    /// When it's due, as a person reads it: `every 5 minutes`, `daily at 08:00 (Europe/Berlin)`.
    public var described: String {
        func time(_ hour: Int, _ minute: Int) -> String {
            (hour < 10 ? "0" : "") + "\(hour):" + (minute < 10 ? "0" : "") + "\(minute)"
        }
        switch self {
        case .every(let minutes): return minutes == 1 ? "every minute" : "every \(minutes) minutes"
        case .daily(let hour, let minute, let timeZone): return "daily at \(time(hour, minute)) (\(timeZone))"
        case .weekly(let weekdays, let hour, let minute, let timeZone):
            let days = weekdays.map(\.rawValue).joined(separator: ", ")
            return "every \(days) at \(time(hour, minute)) (\(timeZone))"
        }
    }

    /// The rule it's due by, or why it can't be: what Swift's calendar takes.
    public func rule() throws(ScheduleProblem) -> Calendar.RecurrenceRule {
        switch self {
        case .every(let minutes):
            guard minutes > 0 else { throw ScheduleProblem("`every(minutes: \(minutes))` is due every 1 minute or more.") }
            return Calendar.RecurrenceRule(
                calendar: Calendar(identifier: .gregorian), frequency: .minutely, interval: minutes)
        case .daily(let hour, let minute, let timeZone):
            return Calendar.RecurrenceRule(
                calendar: try Self.calendar(timeZone), frequency: .daily,
                hours: [try Self.hour(hour)], minutes: [try Self.minute(minute)])
        case .weekly(let weekdays, let hour, let minute, let timeZone):
            guard !weekdays.isEmpty else { throw ScheduleProblem("`weekly` is due on at least one day.") }
            return Calendar.RecurrenceRule(
                calendar: try Self.calendar(timeZone), frequency: .weekly,
                weekdays: weekdays.map { .every($0.weekday) }, hours: [try Self.hour(hour)],
                minutes: [try Self.minute(minute)])
        }
    }

    private static func calendar(_ timeZone: String) throws(ScheduleProblem) -> Calendar {
        guard let zone = TimeZone(identifier: timeZone) else {
            throw ScheduleProblem("`\(timeZone)` isn't an IANA time zone.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private static func hour(_ hour: Int) throws(ScheduleProblem) -> Int {
        guard (0...23).contains(hour) else { throw ScheduleProblem("`hour: \(hour)` is from 0 to 23.") }
        return hour
    }

    private static func minute(_ minute: Int) throws(ScheduleProblem) -> Int {
        guard (0...59).contains(minute) else { throw ScheduleProblem("`minute: \(minute)` is from 0 to 59.") }
        return minute
    }
}

/// Why a schedule can't be due as it's written.
public struct ScheduleProblem: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// When something's due once: at a date.
@Describable
public enum Timer: Codable, Sendable, Equatable {
    /// At this date.
    case at(Date)

    /// The date it's due at.
    public var date: Date {
        switch self {
        case .at(let date): date
        }
    }

    /// When it's due, as a person reads it.
    public var described: String {
        "at \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// What makes something due: a schedule, again and again, or a timer, once.
public enum When: Codable, Sendable, Equatable {
    case schedule(Schedule)
    case timer(Timer)
}

/// A day of the week.
@Describable
public enum Weekday: String, Codable, Sendable, CaseIterable {
    case sunday, monday, tuesday, wednesday, thursday, friday, saturday

    fileprivate var weekday: Locale.Weekday {
        switch self {
        case .sunday: .sunday
        case .monday: .monday
        case .tuesday: .tuesday
        case .wednesday: .wednesday
        case .thursday: .thursday
        case .friday: .friday
        case .saturday: .saturday
        }
    }
}
