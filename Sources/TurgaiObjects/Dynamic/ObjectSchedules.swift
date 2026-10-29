import DiscoverableActors
import DistributedCluster
import DurableWorkflows
import Foundation
import TurgaiDomain

/// When something's due: every so many minutes, every day at a time, or on days of the week at a
/// time, in an IANA time zone. An object's property of this type is due as it says: each time,
/// the object's `on<Property>Fired(at:)` is called.
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
    public func rule() throws(CodeProblem) -> Calendar.RecurrenceRule {
        switch self {
        case .every(let minutes):
            guard minutes > 0 else { throw CodeProblem("`every(minutes: \(minutes))` is due every 1 minute or more.") }
            return Calendar.RecurrenceRule(
                calendar: Calendar(identifier: .gregorian), frequency: .minutely, interval: minutes)
        case .daily(let hour, let minute, let timeZone):
            return Calendar.RecurrenceRule(
                calendar: try Self.calendar(timeZone), frequency: .daily,
                hours: [try Self.hour(hour)], minutes: [try Self.minute(minute)])
        case .weekly(let weekdays, let hour, let minute, let timeZone):
            guard !weekdays.isEmpty else { throw CodeProblem("`weekly` is due on at least one day.") }
            return Calendar.RecurrenceRule(
                calendar: try Self.calendar(timeZone), frequency: .weekly,
                weekdays: weekdays.map { .every($0.weekday) }, hours: [try Self.hour(hour)],
                minutes: [try Self.minute(minute)])
        }
    }

    private static func calendar(_ timeZone: String) throws(CodeProblem) -> Calendar {
        guard let zone = TimeZone(identifier: timeZone) else {
            throw CodeProblem("`\(timeZone)` isn't an IANA time zone.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private static func hour(_ hour: Int) throws(CodeProblem) -> Int {
        guard (0...23).contains(hour) else { throw CodeProblem("`hour: \(hour)` is from 0 to 23.") }
        return hour
    }

    private static func minute(_ minute: Int) throws(CodeProblem) -> Int {
        guard (0...59).contains(minute) else { throw CodeProblem("`minute: \(minute)` is from 0 to 59.") }
        return minute
    }

    /// The method that handles `property`'s schedule being due: `onMorningFired` for `morning`.
    static func handler(for property: String) -> String {
        "on" + property.prefix(1).uppercased() + property.dropFirst() + "Fired"
    }
}

/// When something's due once: at a date. An object's property of this type is due then: the
/// object's `on<Property>Fired(at:)` is called, once.
@Describable
public enum Timer: Codable, Sendable, Equatable {
    /// Once, at this date.
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

/// What makes an object's property due: a schedule, again and again, or a timer, once.
public enum ObjectDue: Codable, Sendable, Equatable {
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

/// An object's property being due: which object, and the property that holds it, with who made the
/// object, in which group: whose group says what its doing may do.
public struct ObjectFiring: Codable, Sendable, Equatable {
    public let object: ObjectIdentity
    public let property: String
    public let maker: UserID
    public let group: GroupID
    /// What makes it due, and the chat the object was made in, which lists it.
    public let due: ObjectDue
    public let place: ConversationID?

    /// The durable schedule of `object`'s `property`: one for each, the same after every restart.
    static func scheduleID(of object: ObjectIdentity, _ property: String) -> ScheduleID {
        ScheduleID(rawValue: "turgai-object-\(object.rawValue)-\(property)")
    }

    /// The durable timer of `object`'s `property` for `date`: one for each date it's set to, which
    /// fires once, however often it's started.
    static func timerID(of object: ObjectIdentity, _ property: String, at date: Date) -> WorkflowID {
        WorkflowID(
            rawValue: "turgai-object-timer-\(object.rawValue)-\(property)-\(Int(date.timeIntervalSince1970))")
    }
}

/// An object's schedule, kept durably: each time it's due, its object is told.
@Workflow
public struct ObjectScheduleWorkflow {
    public typealias Activities = ObjectScheduleActivities
    public typealias Input = ObjectFiring
    public typealias Output = DurableVoid

    public init() {}

    public func run(input: Input, context: WorkflowContext) async throws -> Output {
        try await context.executeActivity(ObjectScheduleActivities.Activities.Fire.self, input: input)
    }
}

/// An object's timer, kept durably: when it's due, its object is told, once.
@Workflow
public struct ObjectTimerWorkflow {
    public typealias Activities = ObjectScheduleActivities
    public typealias Input = ObjectFiring
    public typealias Output = DurableVoid

    public init() {}

    public func run(input: Input, context: WorkflowContext) async throws -> Output {
        if case .timer(let timer) = input.due {
            try await context.sleep(until: timer.date, summary: "timer")
        }
        return try await context.executeActivity(ObjectScheduleActivities.Activities.Fire.self, input: input)
    }
}

@ActivityContainer
public struct ObjectScheduleActivities {
    public init() {}

    /// Tells the object its schedule is due. The call is let in on its maker's standing scope,
    /// which spends nothing; the object handles it as its own doing, as it does its tasks.
    @Activity
    public func fire(input: ObjectFiring, context: ActivityContext) async throws -> DurableVoid {
        let group = try await Group.resolve(on: context.system, id: input.group)
        let scope = try await group.scope(of: input.maker)
        try await CallChain.$current.withValue(.own(input.object, for: scope, in: nil)) {
            try await DynamicObject.resolve(on: context.system, identity: input.object).fired(input.property)
        }
        return DurableVoid()
    }
}
