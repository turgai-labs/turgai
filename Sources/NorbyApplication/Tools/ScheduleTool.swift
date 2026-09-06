import DistributedCluster
import DurableWorkflows
import Foundation
import Hail
import NorbyDomain

/// Creates, replaces or cancels a durable recurring schedule for the current
/// conversation.
public struct ScheduleTool: Tool {
    public struct Recurrence: Codable, Sendable, Equatable {
        public enum Frequency: String, Codable, Sendable, Equatable, CaseIterable {
            case daily
            case weekly
        }

        public enum Weekday: String, Codable, Sendable, Equatable, CaseIterable {
            case sunday
            case monday
            case tuesday
            case wednesday
            case thursday
            case friday
            case saturday

            fileprivate var foundationValue: Locale.Weekday {
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
        public let timeZone: String
        public let hour: Int
        public let minute: Int
        public let weekdays: [Weekday]

        private enum CodingKeys: String, CodingKey {
            case frequency
            case interval
            case timeZone = "time_zone"
            case hour
            case minute
            case weekdays
        }

        public init(
            frequency: Frequency,
            interval: Int = 1,
            timeZone: String,
            hour: Int,
            minute: Int,
            weekdays: [Weekday] = []
        ) {
            self.frequency = frequency
            self.interval = interval
            self.timeZone = timeZone
            self.hour = hour
            self.minute = minute
            self.weekdays = weekdays
        }

        fileprivate func foundationRule() throws -> Calendar.RecurrenceRule {
            guard interval > 0 else {
                throw Error.invalidInterval(interval)
            }
            guard (0...23).contains(hour) else {
                throw Error.invalidHour(hour)
            }
            guard (0...59).contains(minute) else {
                throw Error.invalidMinute(minute)
            }
            guard let zone = TimeZone(identifier: timeZone) else {
                throw Error.invalidTimeZone(timeZone)
            }
            if frequency == .weekly, weekdays.isEmpty {
                throw Error.missingWeekdays
            }
            if frequency == .daily, !weekdays.isEmpty {
                throw Error.invalidWeekdays
            }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let foundationWeekdays = weekdays.map {
                Calendar.RecurrenceRule.Weekday.every($0.foundationValue)
            }
            let foundationFrequency: Calendar.RecurrenceRule.Frequency = switch frequency {
            case .daily: .daily
            case .weekly: .weekly
            }
            return Calendar.RecurrenceRule(
                calendar: calendar,
                frequency: foundationFrequency,
                interval: interval,
                weekdays: foundationWeekdays,
                hours: [hour],
                minutes: [minute]
            )
        }
    }

    public enum Operation: String, Codable, Sendable, Equatable {
        case create
        case replace
        case cancel
    }

    public struct Input: Codable, Sendable {
        public let operation: Operation
        public let scheduleID: String?
        public let action: DeferredAction.Kind?
        public let message: String?
        public let instruction: String?
        public let recurrence: Recurrence?

        private enum CodingKeys: String, CodingKey {
            case operation
            case scheduleID = "schedule_id"
            case action
            case message
            case instruction
            case recurrence
        }

        public init(
            operation: Operation = .create,
            scheduleID: String? = nil,
            action: DeferredAction.Kind? = nil,
            message: String? = nil,
            instruction: String? = nil,
            recurrence: Recurrence? = nil
        ) {
            self.operation = operation
            self.scheduleID = scheduleID
            self.action = action
            self.message = message
            self.instruction = instruction
            self.recurrence = recurrence
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case emptyMessage
        case emptyInstruction
        case missingAction
        case missingMessage
        case missingInstruction
        case missingRecurrence
        case missingScheduleID
        case emptyScheduleID
        case invalidInterval(Int)
        case invalidHour(Int)
        case invalidMinute(Int)
        case invalidTimeZone(String)
        case missingWeekdays
        case invalidWeekdays
        case invalidConversationID(String)
        case invalidParticipantID(String)
    }

    public let name = "schedule"
    public let description =
        "Manage a durable recurring action for this conversation. Use create for a new schedule, replace with the schedule_id from an earlier result to change it, and cancel with that schedule_id to remove it. Use notify for a user-visible message, whether the user says 'remind' or 'notify'. Use prompt_agent when Norby should wake up, use its tools, and compose a fresh response. Recurrence supports daily or weekly local times."

    private let actorSystem: ClusterSystem
    private let context: AgentTurnContext
    private let snapshotPolicy: AgentSnapshotPolicy

    public init(
        actorSystem: ClusterSystem,
        context: AgentTurnContext,
        snapshotPolicy: AgentSnapshotPolicy = .default
    ) {
        self.actorSystem = actorSystem
        self.context = context
        self.snapshotPolicy = snapshotPolicy
    }

    public var schema: LLMToolSchema {
        LLMToolSchema(
            type: "function",
            function: LLMToolSchema.FunctionSchema(
                name: name,
                description: description,
                parameters: LLMToolSchema.ParameterSchema(
                    type: "object",
                    properties: [
                        "operation": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "The operation: create, replace, or cancel.",
                            enumValues: ["create", "replace", "cancel"]
                        ),
                        "schedule_id": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "The opaque schedule_id returned when the schedule was created. Required for replace and cancel.",
                            enumValues: nil
                        ),
                        "action": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "notify sends a message to the user; prompt_agent starts a future agent turn.",
                            enumValues: ["notify", "prompt_agent"]
                        ),
                        "message": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "Required for notify. The final user-visible message to send when the schedule fires.",
                            enumValues: nil
                        ),
                        "instruction": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "Required for prompt_agent. The complete request to give Norby when the schedule fires.",
                            enumValues: nil
                        ),
                        "recurrence": recurrenceSchema,
                    ],
                    required: ["operation"]
                )
            )
        )
    }

    public func effect(for input: Input) throws -> Schedule {
        try validate(input)
        return Schedule()
    }

    public func execute(
        input: Input,
        token: borrowing EffectToken<Schedule>
    ) async throws -> String {
        try validate(input)
        switch input.operation {
        case .cancel:
            let scheduleID = try scheduleID(from: input)
            try await token.cancel(on: actorSystem, id: scheduleID)
            return "Recurring schedule cancelled."

        case .create, .replace:
            let definition = try definition(from: input)
            let target = try target()
            let action = deferredAction(from: definition)
            let request = Schedule.Request(
                ownerID: target.ownerID,
                conversationID: target.conversationID,
                participantID: target.participantID,
                action: action,
                snapshotPolicy: snapshotPolicy
            )
            let scheduleID: ScheduleID
            switch input.operation {
            case .create:
                scheduleID = ScheduleID(
                    ownerID: target.ownerID,
                    conversationID: target.conversationID,
                    action: action,
                    recurrence: definition.recurrence
                )
            case .replace:
                scheduleID = try self.scheduleID(from: input)
                try await token.cancel(on: actorSystem, id: scheduleID)
            case .cancel:
                fatalError("unreachable")
            }

            try await token.schedule(
                on: actorSystem,
                id: scheduleID,
                recurrence: definition.recurrence,
                request: request
            )

            let result: String
            switch definition.action {
            case .notify:
                result = input.operation == .replace
                    ? "Recurring notification replaced."
                    : "Recurring notification scheduled."
            case .promptAgent:
                result = input.operation == .replace
                    ? "Recurring agent task replaced."
                    : "Recurring agent task scheduled."
            }
            return result + " schedule_id: " + scheduleID.rawValue + "."
        }
    }

    private func validate(_ input: Input) throws {
        switch input.operation {
        case .cancel:
            _ = try scheduleID(from: input)
        case .create, .replace:
            _ = try definition(from: input)
            if input.operation == .replace {
                _ = try scheduleID(from: input)
            }
        }
    }

    private func definition(
        from input: Input
    ) throws -> Definition {
        guard let action = input.action else {
            throw Error.missingAction
        }
        guard let recurrence = input.recurrence else {
            throw Error.missingRecurrence
        }
        let foundationRecurrence = try recurrence.foundationRule()
        switch action {
        case .notify:
            guard let message = input.message else { throw Error.missingMessage }
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Error.emptyMessage
            }
            return Definition(
                action: action,
                content: message.trimmingCharacters(in: .whitespacesAndNewlines),
                recurrence: foundationRecurrence
            )
        case .promptAgent:
            guard let instruction = input.instruction else { throw Error.missingInstruction }
            guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Error.emptyInstruction
            }
            return Definition(
                action: action,
                content: instruction.trimmingCharacters(in: .whitespacesAndNewlines),
                recurrence: foundationRecurrence
            )
        }
    }

    private struct Definition {
        let action: DeferredAction.Kind
        let content: String
        let recurrence: Calendar.RecurrenceRule
    }

    private func deferredAction(from definition: Definition) -> DeferredAction {
        DeferredAction(kind: definition.action, content: definition.content)
    }

    private func scheduleID(from input: Input) throws -> ScheduleID {
        guard let rawValue = input.scheduleID else {
            throw Error.missingScheduleID
        }
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.emptyScheduleID
        }
        return ScheduleID(rawValue: rawValue)
    }

    private struct Target {
        let ownerID: NorbyDomain.UserID
        let conversationID: ConversationID
        let participantID: ParticipantID
    }

    private func target() throws -> Target {
        guard let conversationID = ConversationID(
            stableKey: context.agentID.contextID.rawValue
        ) else {
            throw Error.invalidConversationID(context.agentID.contextID.rawValue)
        }
        guard case .text(let sender, _, _) = context.message else {
            throw Error.invalidParticipantID("non-text message")
        }

        let participantPrefix = "participant:\(conversationID.channel.rawValue):"
        guard sender.hasPrefix(participantPrefix) else {
            throw Error.invalidParticipantID(sender)
        }
        let participantRawValue = String(sender.dropFirst(participantPrefix.count))
        guard !participantRawValue.isEmpty else {
            throw Error.invalidParticipantID(sender)
        }

        return Target(
            ownerID: NorbyDomain.UserID(rawValue: sender),
            conversationID: conversationID,
            participantID: ParticipantID(
                channel: conversationID.channel,
                rawValue: participantRawValue
            )
        )
    }
}

private let recurrenceSchema = LLMToolSchema.PropertySchema(
    type: "object",
    description: "The local recurrence rule. Use daily for every N days, or weekly with one or more weekdays.",
    enumValues: nil,
    properties: [
        "frequency": LLMToolSchema.PropertySchema(
            type: "string",
            description: "How often the action repeats.",
            enumValues: ["daily", "weekly"]
        ),
        "interval": LLMToolSchema.PropertySchema(
            type: "integer",
            description: "Repeat every this many periods. Usually 1.",
            enumValues: nil
        ),
        "time_zone": LLMToolSchema.PropertySchema(
            type: "string",
            description: "IANA time zone, for example Europe/Berlin.",
            enumValues: nil
        ),
        "hour": LLMToolSchema.PropertySchema(
            type: "integer",
            description: "Local hour from 0 through 23.",
            enumValues: nil
        ),
        "minute": LLMToolSchema.PropertySchema(
            type: "integer",
            description: "Local minute from 0 through 59.",
            enumValues: nil
        ),
        "weekdays": LLMToolSchema.PropertySchema(
            type: "array",
            description: "For weekly rules, the weekdays on which the action runs. Use an empty array for daily rules.",
            enumValues: nil,
            items: LLMToolSchema.PropertySchema(
                type: "string",
                description: "A weekday name.",
                enumValues: [
                    "sunday", "monday", "tuesday", "wednesday",
                    "thursday", "friday", "saturday",
                ]
            )
        ),
    ],
    required: ["frequency", "interval", "time_zone", "hour", "minute", "weekdays"]
)
