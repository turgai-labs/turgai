import AnyLanguageModel
import CryptoKit
import DistributedCluster
import DurableWorkflows
import Hail
import NorbyDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Durable recurring schedule domain and its scoped capability.
public struct Schedule: Sendable {

    public struct Request: Codable, Sendable {
        public let ownerID: NorbyDomain.UserID
        public let conversationID: ConversationID
        public let participantID: ParticipantID
        public let author: MessageAuthor?
        public let action: DeferredAction
        public let agentDirectoryID: AgentDirectoryID
        public let agentRole: String
        public let snapshotPolicy: AgentSnapshotPolicy

        public init(
            ownerID: NorbyDomain.UserID,
            conversationID: ConversationID,
            participantID: ParticipantID,
            author: MessageAuthor? = nil,
            action: DeferredAction,
            agentDirectoryID: AgentDirectoryID = "agent-directory",
            agentRole: String = "conversation",
            snapshotPolicy: AgentSnapshotPolicy = .default
        ) {
            self.ownerID = ownerID
            self.conversationID = conversationID
            self.participantID = participantID
            self.author = author
            self.action = action
            self.agentDirectoryID = agentDirectoryID
            self.agentRole = agentRole
            self.snapshotPolicy = snapshotPolicy
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case emptyText
        case emptyScheduleID
        case invalidConversationID(String)
        case invalidParticipantID(String)
    }

    public struct Info: Sendable {
        public let id: ScheduleID
        public let recurrence: Calendar.RecurrenceRule
        public let action: DeferredAction
        public let createdAt: Date
        public let lastFiredAt: Date?
        public let nextFireAt: Date?
        public let nextFireIn: Duration?
        public let paused: Bool
        public let executions: [ScheduleExecutionState]

        public init(
            id: ScheduleID,
            recurrence: Calendar.RecurrenceRule,
            action: DeferredAction,
            createdAt: Date,
            lastFiredAt: Date?,
            nextFireAt: Date?,
            nextFireIn: Duration?,
            paused: Bool,
            executions: [ScheduleExecutionState]
        ) {
            self.id = id
            self.recurrence = recurrence
            self.action = action
            self.createdAt = createdAt
            self.lastFiredAt = lastFiredAt
            self.nextFireAt = nextFireAt
            self.nextFireIn = nextFireIn
            self.paused = paused
            self.executions = executions
        }
    }

    /// A connection outage should not silently consume a scheduled delivery.
    /// The workflow retries the activity and the policy is persisted by the
    /// durable runtime for each occurrence.
    public static let defaultRetryPolicy = RetryPolicy(
        initialInterval: .seconds(5),
        backoffCoefficient: 2,
        maximumInterval: .seconds(300),
        maximumAttempts: 6
    )

    static func schedule(
        id: ScheduleID,
        recurrence: Calendar.RecurrenceRule,
        request: Request,
        retryPolicy: RetryPolicy? = Self.defaultRetryPolicy,
        overlapPolicy: ScheduleOverlapPolicy = .skip,
        workflows: WorkflowActions
    ) async throws {
        guard !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.emptyScheduleID
        }
        guard !request.action.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.emptyText
        }

        try await workflows.schedule(id, recurrence, request, retryPolicy, overlapPolicy)
    }

    static func cancel(
        _ id: ScheduleID,
        workflows: WorkflowActions
    ) async throws {
        try await workflows.cancelSchedule(id)
    }

    static func trigger(
        _ id: ScheduleID,
        workflows: WorkflowActions
    ) async throws -> ScheduleTriggerOutcome {
        try await workflows.triggerSchedule(id)
    }

    static func list(
        conversationID: ConversationID,
        workflows: WorkflowActions
    ) async throws -> [Info] {
        let descriptions = try await workflows.listSchedules()
        let decoder = JSONDecoder()
        return descriptions.compactMap { description in
            guard
                let request = try? decoder.decode(
                    Request.self,
                    from: description.inputData
                ), request.conversationID == conversationID
            else {
                return nil
            }
            return Info(
                id: description.id,
                recurrence: description.recurrence,
                action: request.action,
                createdAt: description.createdAt,
                lastFiredAt: description.lastFiredAt,
                nextFireAt: description.nextFireAt,
                nextFireIn: description.nextFireIn,
                paused: description.paused,
                executions: description.executions
            )
        }
        .sorted { left, right in
            switch (left.nextFireAt, right.nextFireAt) {
            case (let left?, let right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return left.id.rawValue < right.id.rawValue
            }
        }
    }

    fileprivate static func messageID(for workflowID: WorkflowID) -> MessageID {
        MessageID(rawValue: norbyDeterministicUUID("message:\(workflowID.rawValue)"))
    }

    fileprivate static func turnID(for workflowID: WorkflowID) -> NorbyDomain.TurnID {
        NorbyDomain.TurnID(rawValue: norbyDeterministicUUID("turn:\(workflowID.rawValue)"))
    }
}

public struct ScheduleScheduledResult: Sendable {
    public let id: ScheduleID
    public let action: DeferredAction.Kind
    public let replaced: Bool
}

public struct CreateScheduleEffect: ScopedEffect, Sendable {
    public let name = "schedule.create"
    public let id: ScheduleID
    public let recurrence: Calendar.RecurrenceRule
    public let request: Schedule.Request
    public static func run(in token: borrowing EffectToken<Self>) async throws -> ScheduleScheduledResult {
        let (id, recurrence, request) = token.withConfiguration { ($0.id, $0.recurrence, $0.request) }
        try await Schedule.schedule(
            id: id, recurrence: recurrence, request: request, workflows: ActorSystemDependency<Self>.current.workflows)
        return ScheduleScheduledResult(id: id, action: request.action.kind, replaced: false)
    }
}

public struct ReplaceScheduleEffect: ScopedEffect, Sendable {
    public let name = "schedule.replace"
    public let id: ScheduleID
    public let recurrence: Calendar.RecurrenceRule
    public let request: Schedule.Request
    public static func run(in token: borrowing EffectToken<Self>) async throws -> ScheduleScheduledResult {
        let (id, recurrence, request) = token.withConfiguration { ($0.id, $0.recurrence, $0.request) }
        let workflows = ActorSystemDependency<Self>.current.workflows
        try await Schedule.cancel(id, workflows: workflows)
        try await Schedule.schedule(id: id, recurrence: recurrence, request: request, workflows: workflows)
        return ScheduleScheduledResult(id: id, action: request.action.kind, replaced: true)
    }
}

public struct CancelScheduleEffect: ScopedEffect, Sendable {
    public let name = "schedule.cancel"
    public let scheduleID: ScheduleID
    public static func run(in token: borrowing EffectToken<Self>) async throws {
        try await Schedule.cancel(
            token.withConfiguration { $0.scheduleID }, workflows: ActorSystemDependency<Self>.current.workflows)
    }
}

public struct ListSchedulesEffect: ScopedEffect, Sendable {
    public let name = "schedule.list"
    public let conversationID: ConversationID
    public static func run(in token: borrowing EffectToken<Self>) async throws -> [Schedule.Info] {
        try await Schedule.list(
            conversationID: token.withConfiguration { $0.conversationID },
            workflows: ActorSystemDependency<Self>.current.workflows)
    }
}

public struct TriggerScheduleEffect: ScopedEffect, Sendable {
    public let name = "schedule.trigger"
    public let scheduleID: ScheduleID
    public static func run(in token: borrowing EffectToken<Self>) async throws -> ScheduleTriggerOutcome {
        switch try await Schedule.trigger(
            token.withConfiguration { $0.scheduleID }, workflows: ActorSystemDependency<Self>.current.workflows)
        {
        case .triggered: .triggered
        case .skipped: .skipped
        }
    }
}

@Tool("schedule")
public struct ScheduleTools: Sendable {
    public struct Recurrence: Codable, Sendable, Equatable {
        public enum Frequency: String, Codable, Sendable, Equatable, CaseIterable { case daily, weekly }
        public enum Weekday: String, Codable, Sendable, Equatable, CaseIterable {
            case sunday, monday, tuesday, wednesday, thursday, friday, saturday
            var foundationValue: Locale.Weekday {
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
        public let frequency: Frequency
        public let interval: Int
        public let timeZone: TimeZone
        public let hour: Int
        public let minute: Int
        public let weekdays: [Weekday]
        private enum CodingKeys: String, CodingKey {
            case frequency, interval
            case timeZone = "time_zone"
            case hour, minute, weekdays
        }
        public init(
            frequency: Frequency, interval: Int = 1, timeZone: TimeZone, hour: Int, minute: Int,
            weekdays: [Weekday] = []
        ) {
            self.frequency = frequency
            self.interval = interval
            self.timeZone = timeZone
            self.hour = hour
            self.minute = minute
            self.weekdays = weekdays
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            frequency = try c.decode(Frequency.self, forKey: .frequency)
            interval = try c.decode(Int.self, forKey: .interval)
            let id = try c.decode(String.self, forKey: .timeZone)
            guard let zone = TimeZone(identifier: id) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .timeZone, in: c, debugDescription: "Invalid IANA timezone: \(id)")
            }
            timeZone = zone
            hour = try c.decode(Int.self, forKey: .hour)
            minute = try c.decode(Int.self, forKey: .minute)
            weekdays = try c.decode([Weekday].self, forKey: .weekdays)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(frequency, forKey: .frequency)
            try c.encode(interval, forKey: .interval)
            try c.encode(timeZone.identifier, forKey: .timeZone)
            try c.encode(hour, forKey: .hour)
            try c.encode(minute, forKey: .minute)
            try c.encode(weekdays, forKey: .weekdays)
        }
        func foundationRule() throws -> Calendar.RecurrenceRule {
            guard interval > 0 else { throw Error.invalidInterval(interval) }
            guard (0...23).contains(hour) else { throw Error.invalidHour(hour) }
            guard (0...59).contains(minute) else { throw Error.invalidMinute(minute) }
            guard frequency == .weekly ? !weekdays.isEmpty : weekdays.isEmpty else {
                throw frequency == .weekly ? Error.missingWeekdays : Error.invalidWeekdays
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return Calendar.RecurrenceRule(
                calendar: calendar, frequency: frequency == .daily ? .daily : .weekly, interval: interval,
                weekdays: weekdays.map { .every($0.foundationValue) }, hours: [hour], minutes: [minute])
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case emptyScheduleID
        case invalidInterval(Int)
        case invalidHour(Int)
        case invalidMinute(Int)
        case missingWeekdays, invalidWeekdays
        case invalidTimeZone(String)
    }
    public let context: AgentTurnContext
    public let snapshotPolicy: AgentSnapshotPolicy
    public init(context: AgentTurnContext, snapshotPolicy: AgentSnapshotPolicy = .default) {
        self.context = context
        self.snapshotPolicy = snapshotPolicy
    }

    private func deferredAction(kind: ScheduleToolsAction, message: String?, instruction: String?) throws -> DeferredAction {
        let domainKind: DeferredAction.Kind =
            switch kind {
            case .deliverPreparedMessage: .deliverPreparedMessage
            case .performTask: .performTask
            }
        return try DeferredActionToolSupport.make(kind: domainKind, message: message, instruction: instruction)
    }

    private func recurrence(_ input: ScheduleToolsRecurrenceInput) throws -> Recurrence {
        guard let timeZone = TimeZone(identifier: input.timeZone) else {
            throw Error.invalidTimeZone(input.timeZone)
        }
        let frequency: Recurrence.Frequency =
            switch input.frequency {
            case .daily: .daily
            case .weekly: .weekly
            }
        let weekdays = input.weekdays.map { weekday -> Recurrence.Weekday in
            switch weekday {
            case .sunday: .sunday
            case .monday: .monday
            case .tuesday: .tuesday
            case .wednesday: .wednesday
            case .thursday: .thursday
            case .friday: .friday
            case .saturday: .saturday
            }
        }
        return Recurrence(
            frequency: frequency, interval: input.interval, timeZone: timeZone, hour: input.hour, minute: input.minute,
            weekdays: weekdays)
    }

    @Command("create", description: "Create a recurring schedule that delivers a message or performs a task.")
    public func create(_ input: ScheduleToolsCreateInput) throws -> CreateScheduleEffect {
        let target = try ScheduleTarget(context: context)
        let action = try deferredAction(kind: input.action, message: input.message, instruction: input.instruction)
        let recurrence = try recurrence(input.recurrence).foundationRule()
        return CreateScheduleEffect(
            id: ScheduleID(
                ownerID: target.ownerID, conversationID: target.conversationID, action: action, recurrence: recurrence),
            recurrence: recurrence, request: target.request(action: action, snapshotPolicy: snapshotPolicy))
    }
    @Command("replace", description: "Replace an existing recurring schedule with a new recurrence and action.")
    public func replace(_ input: ScheduleToolsReplaceInput) throws -> ReplaceScheduleEffect {
        guard let id = ScheduleID.scheduleID(from: input.scheduleID) else { throw Error.emptyScheduleID }
        let target = try ScheduleTarget(context: context)
        let action = try deferredAction(kind: input.action, message: input.message, instruction: input.instruction)
        let recurrence = try recurrence(input.recurrence).foundationRule()
        return ReplaceScheduleEffect(
            id: id, recurrence: recurrence, request: target.request(action: action, snapshotPolicy: snapshotPolicy))
    }
    @Command("cancel", description: "Cancel an existing recurring schedule.")
    public func cancel(_ input: ScheduleToolsCancelInput) throws -> CancelScheduleEffect {
        guard let id = ScheduleID.scheduleID(from: input.scheduleID) else { throw Error.emptyScheduleID }
        return CancelScheduleEffect(scheduleID: id)
    }
    @Command("list", description: "List the active recurring schedules for this conversation.")
    public func list(_ input: ScheduleToolsListInput) throws -> ListSchedulesEffect {
        ListSchedulesEffect(conversationID: try ScheduleTarget(context: context).conversationID)
    }
    @Command("trigger", description: "Trigger an existing recurring schedule immediately.")
    public func trigger(_ input: ScheduleToolsTriggerInput) throws -> TriggerScheduleEffect {
        guard let id = ScheduleID.scheduleID(from: input.scheduleID) else { throw Error.emptyScheduleID }
        return TriggerScheduleEffect(scheduleID: id)
    }

    public func render(_ output: ScheduleScheduledResult) -> ToolOutput {
        .text(Self.renderScheduled(id: output.id, action: output.action, replaced: output.replaced))
    }
    public func render(_ output: [Schedule.Info]) -> ToolOutput { .text(Self.renderListed(output)) }
    public func render(_ output: Void) -> ToolOutput { .text("Recurring schedule cancelled.") }
    public func render(_ output: ScheduleTriggerOutcome) -> ToolOutput {
        let text: String =
            switch output {
            case .triggered: "Recurring schedule triggered."
            case .skipped: "Recurring schedule was not triggered because an occurrence is already running."
            }
        return .text(text)
    }
    static func renderScheduled(id: ScheduleID, action: DeferredAction.Kind, replaced: Bool) -> String {
        let prefix =
            switch action {
            case .deliverPreparedMessage:
                replaced ? "Recurring prepared message replaced." : "Recurring prepared message scheduled."
            case .performTask: replaced ? "Recurring task replaced." : "Recurring task scheduled."
            }
        return prefix + " schedule_id: " + id.rawValue + "."
    }
    static func renderListed(_ schedules: [Schedule.Info]) -> String {
        guard !schedules.isEmpty else { return "No active recurring schedules." }
        return schedules.map {
            [
                "schedule_id=\($0.id.rawValue)", "action=\($0.action.kind.rawValue)", "content=\($0.action.content)",
                "next_fire_at=\($0.nextFireAt?.ISO8601Format() ?? "none")",
            ].joined(separator: " | ")
        }.joined(separator: "\n")
    }
}

@Generable
public enum ScheduleToolsAction: Sendable {
    case deliverPreparedMessage
    case performTask
}

@Generable
public enum ScheduleToolsFrequency: Sendable {
    case daily
    case weekly
}

@Generable
public enum ScheduleToolsWeekday: Sendable {
    case sunday, monday, tuesday, wednesday, thursday, friday, saturday
}

// Formerly ScheduleTools.RecurrenceInput; renamed during the no-nested-Generable sweep.
@Generable
public struct ScheduleToolsRecurrenceInput: Sendable {
    public let frequency: ScheduleToolsFrequency
    public let interval: Int
    public let timeZone: String
    public let hour: Int
    public let minute: Int
    public let weekdays: [ScheduleToolsWeekday]
}

// Formerly ScheduleTools.CreateInput; renamed during the no-nested-Generable sweep.
@Generable
public struct ScheduleToolsCreateInput: Sendable {
    public let action: ScheduleToolsAction
    public let message: String?
    public let instruction: String?
    public let recurrence: ScheduleToolsRecurrenceInput
}

// Formerly ScheduleTools.ReplaceInput; renamed during the no-nested-Generable sweep.
@Generable
public struct ScheduleToolsReplaceInput: Sendable {
    public let scheduleID: String
    public let action: ScheduleToolsAction
    public let message: String?
    public let instruction: String?
    public let recurrence: ScheduleToolsRecurrenceInput
}

// Formerly ScheduleTools.CancelInput; renamed during the no-nested-Generable sweep.
@Generable
public struct ScheduleToolsCancelInput: Sendable { public let scheduleID: String }

// Formerly ScheduleTools.ListInput; renamed during the no-nested-Generable sweep.
@Generable
public struct ScheduleToolsListInput: Sendable {}

// Formerly ScheduleTools.TriggerInput; renamed during the no-nested-Generable sweep.
@Generable
public struct ScheduleToolsTriggerInput: Sendable { public let scheduleID: String }

/// Stable identity for one recurring action in one conversation. Calling the
/// tool again with the same action and recurrence addresses the same durable
/// schedule instead of creating a duplicate.
extension ScheduleID {
    static let norbySchedulePrefix = "norby-schedule-"

    static func compactScheduleID(_ id: ScheduleID) -> String {
        id.rawValue.hasPrefix(norbySchedulePrefix)
            ? String(id.rawValue.dropFirst(norbySchedulePrefix.count))
            : id.rawValue
    }

    static func scheduleID(from value: String) -> ScheduleID? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return ScheduleID(
            rawValue: value.hasPrefix(norbySchedulePrefix)
                ? value
                : norbySchedulePrefix + value
        )
    }

    public init(
        ownerID: NorbyDomain.UserID,
        conversationID: ConversationID,
        action: DeferredAction,
        recurrence: Calendar.RecurrenceRule
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let recurrenceData = (try? encoder.encode(recurrence)) ?? Data()
        let recurrenceValue = String(decoding: recurrenceData, as: UTF8.self)
        let value = [
            ownerID.rawValue,
            conversationID.stableKey,
            action.kind.rawValue,
            action.content,
            recurrenceValue,
        ].joined(separator: "\u{1F}")
        self.init(rawValue: "\(Self.norbySchedulePrefix)\(norbyDeterministicUUID(value).uuidString)")
    }
}

internal func norbyDeterministicUUID(_ value: String) -> UUID {
    let digest = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
    return UUID(
        uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
}

@Workflow
public struct ScheduleWorkflow {
    public typealias Activities = ScheduleActivities
    public typealias Input = Schedule.Request
    public typealias Output = DurableVoid

    public init() {}

    public func run(
        input: Input,
        context: WorkflowContext
    ) async throws -> Output {
        try await context.executeActivity(
            ScheduleActivities.Activities.Deliver.self,
            input: input
        )
    }
}

@ActivityContainer
public struct ScheduleActivities {
    @Activity
    public func deliver(
        input: Schedule.Request,
        context: ActivityContext
    ) async throws -> DurableVoid {
        let conversation = try await Conversation.resolve(
            on: context.system,
            conversationID: input.conversationID,
            agentDirectoryID: input.agentDirectoryID,
            agentRole: input.agentRole,
            snapshotPolicy: input.snapshotPolicy
        )

        switch input.action {
        case .deliverPreparedMessage(let message):
            try await conversation.notify(message)

        case .performTask(let instruction):
            let message = InboundMessage(
                id: Schedule.messageID(for: context.workflowID),
                conversationID: input.conversationID,
                participantID: input.participantID,
                userID: input.ownerID,
                author: input.author,
                text: instruction,
                receivedAt: Date()
            )
            try await conversation.send(
                message,
                turnID: Schedule.turnID(for: context.workflowID)
            )
        }

        return DurableVoid()
    }
}
