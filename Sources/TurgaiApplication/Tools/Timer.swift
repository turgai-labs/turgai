import AnyLanguageModel
import DistributedCluster
import DurableWorkflows
import Hail
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Durable one-shot timer domain and its scoped capability.
public struct Timer: Sendable {

    public struct Request: Codable, Sendable {
        public let ownerID: TurgaiDomain.UserID
        public let conversationID: ConversationID
        public let participantID: ParticipantID
        public let author: MessageAuthor?
        public let action: DeferredAction
        public let agentDirectoryID: AgentDirectoryID
        public let agentRole: String

        public init(
            ownerID: TurgaiDomain.UserID,
            conversationID: ConversationID,
            participantID: ParticipantID,
            author: MessageAuthor? = nil,
            action: DeferredAction,
            agentDirectoryID: AgentDirectoryID = "agent-directory",
            agentRole: String = "conversation"
        ) {
            self.ownerID = ownerID
            self.conversationID = conversationID
            self.participantID = participantID
            self.author = author
            self.action = action
            self.agentDirectoryID = agentDirectoryID
            self.agentRole = agentRole
        }
    }

    public struct Input: Codable, Sendable {
        public let fireAt: Date
        public let request: Request

        public init(fireAt: Date, request: Request) {
            self.fireAt = fireAt
            self.request = request
        }
    }

    /// A one-shot calendar occurrence.
    ///
    /// `components` describes the next calendar date matching those fields in
    /// `timeZone`. Relative time belongs to ``Trigger/after(_:)``; this type
    /// never adds model-provided components to the current date.
    public struct Occurrence: Codable, Sendable, Equatable {
        public let components: DateComponents
        public let timeZone: TimeZone

        private enum CodingKeys: String, CodingKey {
            case components
            case timeZone = "time_zone"
        }

        public init(
            components: DateComponents,
            timeZone: TimeZone
        ) {
            self.components = components
            self.timeZone = timeZone
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.components = try container.decode(DateComponents.self, forKey: .components)

            let identifier = try container.decode(String.self, forKey: .timeZone)
            guard let timeZone = TimeZone(identifier: identifier) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .timeZone,
                    in: container,
                    debugDescription: "Invalid IANA timezone: \(identifier)"
                )
            }
            self.timeZone = timeZone
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(components, forKey: .components)
            try container.encode(timeZone.identifier, forKey: .timeZone)
        }
    }

    public enum Trigger: Codable, Sendable, Equatable {
        case after(Duration)
        case at(Occurrence)

        private enum CodingKeys: String, CodingKey {
            case kind
            case amount
            case unit
            case at
        }

        enum Kind: String, Codable, CaseIterable {
            case after
            case at
        }

        enum Unit: String, Codable, CaseIterable {
            case seconds
            case minutes
            case hours
            case days
            case weeks

            var seconds: Int64 {
                switch self {
                case .seconds: 1
                case .minutes: 60
                case .hours: 60 * 60
                case .days: 24 * 60 * 60
                case .weeks: 7 * 24 * 60 * 60
                }
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .after:
                let amount = try container.decode(Int.self, forKey: .amount)
                let unit = try container.decode(Unit.self, forKey: .unit)
                let seconds = Int64(exactly: amount)
                    .map { $0.multipliedReportingOverflow(by: unit.seconds) }
                guard
                    let seconds,
                    !seconds.overflow
                else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .amount,
                        in: container,
                        debugDescription: "Duration is too large"
                    )
                }
                self = .after(.seconds(seconds.partialValue))
            case .at:
                guard container.contains(.at) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .at,
                        in: container,
                        debugDescription:
                            "kind=at requires an at object with components and time_zone; occurrence is not a valid key"
                    )
                }
                self = .at(try container.decode(Occurrence.self, forKey: .at))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .after(let duration):
                try container.encode(Kind.after, forKey: .kind)
                let encoded = try Self.encode(duration: duration)
                try container.encode(encoded.amount, forKey: .amount)
                try container.encode(encoded.unit, forKey: .unit)
            case .at(let occurrence):
                try container.encode(Kind.at, forKey: .kind)
                try container.encode(occurrence, forKey: .at)
            }
        }

        private static func encode(duration: Duration) throws -> (amount: Int, unit: Unit) {
            let components = duration.components
            guard
                components.attoseconds == 0,
                let seconds = Int(exactly: components.seconds)
            else {
                throw EncodingError.invalidValue(
                    duration,
                    EncodingError.Context(
                        codingPath: [],
                        debugDescription: "Timer duration must be whole seconds"
                    )
                )
            }

            let units: [Unit] = [.weeks, .days, .hours, .minutes, .seconds]
            guard let unit = units.first(where: { seconds % Int($0.seconds) == 0 }) else {
                throw EncodingError.invalidValue(
                    duration,
                    EncodingError.Context(
                        codingPath: [],
                        debugDescription: "Timer duration cannot be represented"
                    )
                )
            }
            return (seconds / Int(unit.seconds), unit)
        }

        var timeZoneIdentifier: String? {
            switch self {
            case .after:
                nil
            case .at(let occurrence):
                occurrence.timeZone.identifier
            }
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case emptyText
        case invalidRelativeDuration(Int)
        case emptyOccurrence
        case invalidOccurrenceComponent(name: String, value: Int)
        case occurrenceNotFound

        public var description: String {
            switch self {
            case .emptyText: "timer message or instruction must not be empty"
            case .invalidRelativeDuration(let seconds):
                "relative duration must be positive, got \(seconds) seconds"
            case .emptyOccurrence:
                "a calendar trigger needs at least one calendar field (year, month, day, hour, minute, second, weekday)"
            case .invalidOccurrenceComponent(let name, let value):
                "invalid calendar value: \(name)=\(value) is out of range"
            case .occurrenceNotFound: "no future date matches the given calendar fields"
            }
        }
    }

    public struct Info: Sendable {
        public let id: WorkflowID
        public let fireAt: Date
        public let action: DeferredAction
        public let status: WorkflowStatus

        public init(
            id: WorkflowID,
            fireAt: Date,
            action: DeferredAction,
            status: WorkflowStatus
        ) {
            self.id = id
            self.fireAt = fireAt
            self.action = action
            self.status = status
        }
    }

    public static let defaultRetryPolicy = Schedule.defaultRetryPolicy

    public static func validate(_ trigger: Trigger) throws {
        switch trigger {
        case .after(let duration):
            let seconds = duration.components.seconds
            guard duration > .zero else {
                throw Error.invalidRelativeDuration(Int(seconds))
            }
        case .at(let occurrence):
            try validate(occurrence.components)
            guard hasComponents(occurrence.components) else {
                throw Error.emptyOccurrence
            }
        }
    }

    public static func fireAt(for trigger: Trigger, after now: Date) throws -> Date {
        try validate(trigger)
        switch trigger {
        case .after(let duration):
            let components = duration.components
            let interval =
                Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
            let fireAt = now.addingTimeInterval(interval)
            guard fireAt.timeIntervalSince1970.isFinite else {
                throw Error.invalidRelativeDuration(Int(components.seconds))
            }
            return fireAt
        case .at(let occurrence):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = occurrence.timeZone

            guard
                let fireAt = calendar.nextDate(
                    after: now,
                    matching: occurrence.components,
                    matchingPolicy: .nextTime,
                    repeatedTimePolicy: .first,
                    direction: .forward
                )
            else {
                throw Error.occurrenceNotFound
            }
            return fireAt
        }
    }

    private static func timeZoneIdentifier(for trigger: Trigger) -> String? {
        switch trigger {
        case .after:
            nil
        case .at(let occurrence):
            occurrence.timeZone.identifier
        }
    }

    private static func validate(_ components: DateComponents) throws {
        let ranges: [(String, Int?, ClosedRange<Int>)] = [
            ("month", components.month, 1...12),
            ("day", components.day, 1...31),
            ("hour", components.hour, 0...23),
            ("minute", components.minute, 0...59),
            ("second", components.second, 0...59),
            ("nanosecond", components.nanosecond, 0...999_999_999),
            ("weekday", components.weekday, 1...7),
            ("quarter", components.quarter, 1...4),
            ("week_of_month", components.weekOfMonth, 1...6),
            ("week_of_year", components.weekOfYear, 1...53),
        ]
        if let invalid = ranges.first(where: { _, value, range in
            guard let value else { return false }
            return !range.contains(value)
        }) {
            throw Error.invalidOccurrenceComponent(
                name: invalid.0,
                value: invalid.1 ?? 0
            )
        }
    }

    private static func hasComponents(_ components: DateComponents) -> Bool {
        [
            components.era,
            components.year,
            components.month,
            components.day,
            components.hour,
            components.minute,
            components.second,
            components.nanosecond,
            components.weekday,
            components.weekdayOrdinal,
            components.quarter,
            components.weekOfMonth,
            components.weekOfYear,
            components.yearForWeekOfYear,
        ].contains { $0 != nil }
    }

    static func start(
        id: WorkflowID,
        fireAt: Date,
        request: Request,
        retryPolicy: RetryPolicy? = Self.defaultRetryPolicy,
        workflows: WorkflowActions
    ) async throws {
        guard !request.action.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.emptyText
        }

        try await workflows.startTimer(
            id,
            Input(fireAt: fireAt, request: request),
            retryPolicy
        )
    }

    static func cancel(
        _ id: WorkflowID,
        workflows: WorkflowActions
    ) async throws {
        try await workflows.cancelTimer(id)
    }

    static func list(
        conversationID: ConversationID,
        workflows: WorkflowActions
    ) async throws -> [Info] {
        let descriptions = try await workflows.listTimers()
        let decoder = JSONDecoder()
        return descriptions.compactMap { description in
            guard case .running = description.status,
                let inputData = description.inputData,
                let input = try? decoder.decode(Input.self, from: inputData),
                input.request.conversationID == conversationID
            else {
                return nil
            }
            return Info(
                id: description.id,
                fireAt: input.fireAt,
                action: input.request.action,
                status: description.status
            )
        }
        .sorted { $0.fireAt < $1.fireAt }
    }

    fileprivate static func messageID(for workflowID: WorkflowID) -> MessageID {
        MessageID(rawValue: turgaiDeterministicUUID("message:\(workflowID.rawValue)"))
    }

    fileprivate static func turnID(for workflowID: WorkflowID) -> TurgaiDomain.TurnID {
        TurgaiDomain.TurnID(rawValue: turgaiDeterministicUUID("turn:\(workflowID.rawValue)"))
    }
}

public struct TimerScheduledResult: Sendable {
    public let id: WorkflowID
    public let action: DeferredAction.Kind
    public let fireAt: Date
    public let timeZone: String?
    public let replaced: Bool
}

public struct CreateTimerEffect: ScopedEffect, Sendable {
    public let name = "timer.create"
    public let trigger: Timer.Trigger
    public let request: Timer.Request
    public static func run(in token: borrowing EffectToken<Self>) async throws -> TimerScheduledResult {
        let (trigger, request) = token.withConfiguration { ($0.trigger, $0.request) }
        let now = try await token.withChild(ClockEffect()) { try await ClockEffect.run(in: $0) }
        let fireAt = try Timer.fireAt(for: trigger, after: now)
        let id = WorkflowID(
            ownerID: request.ownerID, conversationID: request.conversationID, action: request.action, fireAt: fireAt)
        try await Timer.start(
            id: id, fireAt: fireAt, request: request, workflows: ActorSystemDependency<Self>.current.workflows)
        return TimerScheduledResult(
            id: id, action: request.action.kind, fireAt: fireAt, timeZone: trigger.timeZoneIdentifier, replaced: false)
    }
}

public struct ReplaceTimerEffect: ScopedEffect, Sendable {
    public let name = "timer.replace"
    public let timerID: WorkflowID
    public let trigger: Timer.Trigger
    public let request: Timer.Request
    public static func run(in token: borrowing EffectToken<Self>) async throws -> TimerScheduledResult {
        let (timerID, trigger, request) = token.withConfiguration { ($0.timerID, $0.trigger, $0.request) }
        let now = try await token.withChild(ClockEffect()) { try await ClockEffect.run(in: $0) }
        let fireAt = try Timer.fireAt(for: trigger, after: now)
        let id = WorkflowID(
            ownerID: request.ownerID, conversationID: request.conversationID, action: request.action, fireAt: fireAt)
        let workflows = ActorSystemDependency<Self>.current.workflows
        try await Timer.cancel(timerID, workflows: workflows)
        try await Timer.start(id: id, fireAt: fireAt, request: request, workflows: workflows)
        return TimerScheduledResult(
            id: id, action: request.action.kind, fireAt: fireAt, timeZone: trigger.timeZoneIdentifier, replaced: true)
    }
}

public struct CancelTimerEffect: ScopedEffect, Sendable {
    public let name = "timer.cancel"
    public let timerID: WorkflowID
    public static func run(in token: borrowing EffectToken<Self>) async throws {
        try await Timer.cancel(
            token.withConfiguration { $0.timerID }, workflows: ActorSystemDependency<Self>.current.workflows)
    }
}

public struct ListTimersEffect: ScopedEffect, Sendable {
    public let name = "timer.list"
    public let conversationID: ConversationID
    public static func run(in token: borrowing EffectToken<Self>) async throws -> [Timer.Info] {
        try await Timer.list(
            conversationID: token.withConfiguration { $0.conversationID },
            workflows: ActorSystemDependency<Self>.current.workflows)
    }
}

@Tool("timer")
public struct TimerTools: Sendable {
    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case emptyMessage, emptyInstruction, emptyTimerID
        case negativeAmount(Int)
        case unknownTimeZone(String)
        case invalidConversationID(String)
        case invalidParticipantID(String)
        public var description: String {
            switch self {
            case .emptyMessage: "deliver_prepared_message requires a non-empty message"
            case .emptyInstruction: "perform_task requires a non-empty instruction"
            case .emptyTimerID: "timer_id must not be empty"
            case .negativeAmount(let value): "timer amount must be zero or positive, got \(value)"
            case .unknownTimeZone(let value):
                "unknown time_zone \"\(value)\"; use an IANA timezone name such as Europe/Berlin"
            case .invalidConversationID(let value): "invalid conversation_id: \(value)"
            case .invalidParticipantID(let value): "invalid participant_id: \(value)"
            }
        }
    }

    public let context: AgentTurnContext
    public init(context: AgentTurnContext) {
        self.context = context
    }

    private func deferredAction(kind: TimerToolsAction, message: String?, instruction: String?) throws -> DeferredAction
    {
        let domainKind: DeferredAction.Kind =
            switch kind {
            case .deliverPreparedMessage: .deliverPreparedMessage
            case .performTask: .performTask
            }
        return try DeferredActionToolSupport.make(kind: domainKind, message: message, instruction: instruction)
    }

    private func after(amount: Int, unit: TimerToolsDurationUnit) throws -> Timer.Trigger {
        let secondsPerUnit: Int64 =
            switch unit {
            case .seconds: 1
            case .minutes: 60
            case .hours: 3_600
            case .days: 86_400
            case .weeks: 604_800
            }
        let seconds = Int64(amount).multipliedReportingOverflow(by: secondsPerUnit)
        guard amount >= 0, !seconds.overflow else { throw Error.negativeAmount(amount) }
        return .after(.seconds(seconds.partialValue))
    }

    private func at(
        hour: Int,
        minute: Int,
        year: Int?,
        month: Int?,
        day: Int?,
        timeZone identifier: String
    ) throws -> Timer.Trigger {
        guard let timeZone = TimeZone(identifier: identifier) else {
            throw Error.unknownTimeZone(identifier)
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return .at(Timer.Occurrence(components: components, timeZone: timeZone))
    }

    @Command(
        "create_after",
        description:
            "Create a one-shot timer that delivers a message or performs a task after a relative delay, e.g. in 90 minutes."
    )
    public func createAfter(_ input: TimerToolsCreateAfterInput) throws -> CreateTimerEffect {
        let target = try TimerTarget(context: context)
        return CreateTimerEffect(
            trigger: try after(amount: input.amount, unit: input.unit),
            request: target.request(
                action: try deferredAction(kind: input.action, message: input.message, instruction: input.instruction)))
    }

    @Command(
        "create_at",
        description:
            "Create a one-shot timer that delivers a message or performs a task at the next occurrence of an exact clock time — today if that time is still ahead, otherwise tomorrow. Use this for exact times like 21:32."
    )
    public func createAt(_ input: TimerToolsCreateAtInput) throws -> CreateTimerEffect {
        let target = try TimerTarget(context: context)
        return CreateTimerEffect(
            trigger: try at(
                hour: input.hour, minute: input.minute, year: input.year, month: input.month,
                day: input.day, timeZone: input.timeZone),
            request: target.request(
                action: try deferredAction(kind: input.action, message: input.message, instruction: input.instruction)))
    }

    @Command(
        "replace_after",
        description: "Replace an existing one-shot timer with a new action and relative delay."
    )
    public func replaceAfter(_ input: TimerToolsReplaceAfterInput) throws -> ReplaceTimerEffect {
        guard let id = WorkflowID.timerID(from: input.timerID) else { throw Error.emptyTimerID }
        let target = try TimerTarget(context: context)
        return ReplaceTimerEffect(
            timerID: id, trigger: try after(amount: input.amount, unit: input.unit),
            request: target.request(
                action: try deferredAction(kind: input.action, message: input.message, instruction: input.instruction)))
    }

    @Command(
        "replace_at",
        description:
            "Replace an existing one-shot timer with a new action and an exact clock time (the next occurrence, as with create_at)."
    )
    public func replaceAt(_ input: TimerToolsReplaceAtInput) throws -> ReplaceTimerEffect {
        guard let id = WorkflowID.timerID(from: input.timerID) else { throw Error.emptyTimerID }
        let target = try TimerTarget(context: context)
        return ReplaceTimerEffect(
            timerID: id,
            trigger: try at(
                hour: input.hour, minute: input.minute, year: input.year, month: input.month,
                day: input.day, timeZone: input.timeZone),
            request: target.request(
                action: try deferredAction(kind: input.action, message: input.message, instruction: input.instruction)))
    }

    @Command("cancel", description: "Cancel an existing one-shot timer.")
    public func cancel(_ input: TimerToolsCancelInput) throws -> CancelTimerEffect {
        guard let id = WorkflowID.timerID(from: input.timerID) else { throw Error.emptyTimerID }
        return CancelTimerEffect(timerID: id)
    }

    @Command("list", description: "List the active one-shot timers for this conversation.")
    public func list(_ input: TimerToolsListInput) throws -> ListTimersEffect {
        ListTimersEffect(conversationID: try TimerTarget(context: context).conversationID)
    }

    public func render(_ output: TimerScheduledResult) -> ToolOutput {
        .text(
            Self.renderScheduled(
                id: output.id, action: output.action, fireAt: output.fireAt, timeZone: output.timeZone,
                replaced: output.replaced))
    }
    public func render(_ output: [Timer.Info]) -> ToolOutput { .text(Self.renderListed(output)) }
    public func render(_ output: Void) -> ToolOutput { .text("One-shot timer cancelled.") }

    static func renderScheduled(
        id: WorkflowID, action: DeferredAction.Kind, fireAt: Date, timeZone: String?, replaced: Bool
    ) -> String {
        let prefix =
            switch action {
            case .deliverPreparedMessage:
                replaced ? "One-shot prepared message replaced." : "One-shot prepared message scheduled."
            case .performTask: replaced ? "One-shot task replaced." : "One-shot task scheduled."
            }
        let plannedTime =
            if let timeZone, let zone = TimeZone(identifier: timeZone) {
                fireAt.formatted(Date.FormatStyle(date: .complete, time: .shortened, timeZone: zone)) + " (\(timeZone))"
            } else { fireAt.ISO8601Format() }
        return "\(prefix) Scheduled for \(plannedTime). The timer ID is \(id.rawValue)."
    }

    static func renderListed(_ timers: [Timer.Info]) -> String {
        guard !timers.isEmpty else { return "No active one-shot timers." }
        return timers.map {
            [
                "timer_id=\($0.id.rawValue)", "action=\($0.action.kind.rawValue)", "content=\($0.action.content)",
                "fire_at=\($0.fireAt.ISO8601Format())",
            ].joined(separator: " | ")
        }.joined(separator: "\n")
    }
}

@Generable
public enum TimerToolsAction: Sendable {
    case deliverPreparedMessage
    case performTask
}

@Generable
public enum TimerToolsDurationUnit: Sendable, Codable {
    case seconds
    case minutes
    case hours
    case days
    case weeks
}

@Generable
public struct TimerToolsCreateAfterInput: Sendable {
    public let action: TimerToolsAction
    public let message: String?
    public let instruction: String?
    /// Non-negative whole delay, in `unit`.
    public let amount: Int
    public let unit: TimerToolsDurationUnit
}

@Generable
public struct TimerToolsCreateAtInput: Sendable {
    public let action: TimerToolsAction
    public let message: String?
    public let instruction: String?
    /// The timer fires at the next occurrence of this clock time, in
    /// `timeZone`: today if it is still ahead, otherwise tomorrow. Date
    /// fields pin a specific day; leave them unset for "today or tomorrow".
    public let hour: Int
    public let minute: Int
    public let year: Int?
    public let month: Int?
    public let day: Int?
    /// IANA timezone name such as Europe/Berlin.
    public let timeZone: String
}

@Generable
public struct TimerToolsReplaceAfterInput: Sendable {
    public let timerID: String
    public let action: TimerToolsAction
    public let message: String?
    public let instruction: String?
    public let amount: Int
    public let unit: TimerToolsDurationUnit
}

@Generable
public struct TimerToolsReplaceAtInput: Sendable {
    public let timerID: String
    public let action: TimerToolsAction
    public let message: String?
    public let instruction: String?
    public let hour: Int
    public let minute: Int
    public let year: Int?
    public let month: Int?
    public let day: Int?
    public let timeZone: String
}

// Formerly TimerTools.CancelInput; renamed during the no-nested-Generable sweep.
@Generable
public struct TimerToolsCancelInput: Sendable {
    public let timerID: String
}

// Formerly TimerTools.ListInput; renamed during the no-nested-Generable sweep.
@Generable
public struct TimerToolsListInput: Sendable {}

extension WorkflowID {
    static let turgaiTimerPrefix = "turgai-timer-"

    static func compactTimerID(_ id: WorkflowID) -> String {
        id.rawValue.hasPrefix(turgaiTimerPrefix)
            ? String(id.rawValue.dropFirst(turgaiTimerPrefix.count))
            : id.rawValue
    }

    static func timerID(from value: String) -> WorkflowID? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return WorkflowID(
            rawValue: value.hasPrefix(turgaiTimerPrefix)
                ? value
                : turgaiTimerPrefix + value
        )
    }

    /// Stable identity for a one-shot action. The fire date is part of the
    /// identity so moving a timer creates a new workflow rather than trying
    /// to reuse a completed one.
    public init(
        ownerID: TurgaiDomain.UserID,
        conversationID: ConversationID,
        action: DeferredAction,
        fireAt: Date
    ) {
        let value = [
            ownerID.rawValue,
            conversationID.stableKey,
            action.kind.rawValue,
            action.content,
            String(fireAt.timeIntervalSince1970),
        ].joined(separator: "\u{1F}")
        self.init(rawValue: "\(Self.turgaiTimerPrefix)\(turgaiDeterministicUUID(value).uuidString)")
    }
}

@Workflow
public struct TimerWorkflow {
    public typealias Activities = TimerActivities
    public typealias Input = Timer.Input
    public typealias Output = DurableVoid

    public init() {}

    public func run(
        input: Input,
        context: WorkflowContext
    ) async throws -> Output {
        try await context.sleep(
            until: input.fireAt,
            summary: "timer"
        )
        return try await context.executeActivity(
            TimerActivities.Activities.Deliver.self,
            input: input.request
        )
    }
}

@ActivityContainer
public struct TimerActivities {
    @Activity
    public func deliver(
        input: Timer.Request,
        context: ActivityContext
    ) async throws -> DurableVoid {
        let conversation = try await Conversation.resolve(
            on: context.system,
            conversationID: input.conversationID,
            agentDirectoryID: input.agentDirectoryID,
            agentRole: input.agentRole
        )

        switch input.action {
        case .deliverPreparedMessage(let message):
            try await conversation.notify(message)

        case .performTask(let instruction):
            let message = InboundMessage(
                id: Timer.messageID(for: context.workflowID),
                conversationID: input.conversationID,
                participantID: input.participantID,
                userID: input.ownerID,
                author: input.author,
                text: instruction,
                receivedAt: Date()
            )
            try await conversation.send(
                message,
                turnID: Timer.turnID(for: context.workflowID)
            )
        }

        return DurableVoid()
    }
}
