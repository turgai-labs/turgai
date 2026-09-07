import DurableWorkflows
import Hail
import NorbyDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

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
        public let timeZone: TimeZone
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
            timeZone: TimeZone,
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

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.frequency = try container.decode(Frequency.self, forKey: .frequency)
            self.interval = try container.decode(Int.self, forKey: .interval)
            let identifier = try container.decode(String.self, forKey: .timeZone)
            guard let timeZone = TimeZone(identifier: identifier) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .timeZone,
                    in: container,
                    debugDescription: "Invalid IANA timezone: \(identifier)"
                )
            }
            self.timeZone = timeZone
            self.hour = try container.decode(Int.self, forKey: .hour)
            self.minute = try container.decode(Int.self, forKey: .minute)
            self.weekdays = try container.decode([Weekday].self, forKey: .weekdays)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(frequency, forKey: .frequency)
            try container.encode(interval, forKey: .interval)
            try container.encode(timeZone.identifier, forKey: .timeZone)
            try container.encode(hour, forKey: .hour)
            try container.encode(minute, forKey: .minute)
            try container.encode(weekdays, forKey: .weekdays)
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
            let zone = timeZone
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
            let foundationFrequency: Calendar.RecurrenceRule.Frequency =
                switch frequency {
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
        case list
        case trigger
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
        case missingWeekdays
        case invalidWeekdays
        case invalidConversationID(String)
        case invalidParticipantID(String)
    }

    public let name = "schedule"
    public let description =
        "Manage durable recurring actions for this conversation. Use create for a new schedule, replace with its schedule_id to change it, cancel to remove it, list to inspect active schedules, or trigger to run one immediately as a test without changing its next planned time. Use notify for a user-visible message and prompt_agent when Norby should wake up, use its tools, and compose a fresh response. Recurrence supports daily or weekly local times."

    private let context: AgentTurnContext
    private let snapshotPolicy: AgentSnapshotPolicy

    public init(
        context: AgentTurnContext,
        snapshotPolicy: AgentSnapshotPolicy = .default
    ) {
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
                            description: "The operation: create, replace, cancel, list, or trigger.",
                            enumValues: ["create", "replace", "cancel", "list", "trigger"]
                        ),
                        "schedule_id": LLMToolSchema.PropertySchema(
                            type: "string",
                            description:
                                "The opaque schedule_id returned when the schedule was created. Required for replace, cancel, and trigger.",
                            enumValues: nil
                        ),
                        "action": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "notify sends a message to the user; prompt_agent starts a future agent turn.",
                            enumValues: ["notify", "prompt_agent"]
                        ),
                        "message": LLMToolSchema.PropertySchema(
                            type: "string",
                            description:
                                "Required for notify. The final user-visible message to send when the schedule fires.",
                            enumValues: nil
                        ),
                        "instruction": LLMToolSchema.PropertySchema(
                            type: "string",
                            description:
                                "Required for prompt_agent. The complete request to give Norby when the schedule fires.",
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
        return Schedule(
            operation: try operation(from: input)
        )
    }

    public func run(
        input: Input,
        token: borrowing EffectToken<Schedule>
    ) async throws -> String {
        try validate(input)
        let result = try await Schedule.run(in: token)
        return render(result, action: input.action)
    }

    private func validate(_ input: Input) throws {
        switch input.operation {
        case .cancel:
            _ = try scheduleID(from: input)
        case .list:
            break
        case .trigger:
            _ = try scheduleID(from: input)
        case .create, .replace:
            _ = try definition(from: input)
            if input.operation == .replace {
                _ = try scheduleID(from: input)
            }
        }
    }

    private func render(
        _ result: Schedule.Result,
        action: DeferredAction.Kind?
    ) -> String {
        switch result {
        case .cancelled:
            return "Recurring schedule cancelled."
        case .triggered(.triggered):
            return "Recurring schedule triggered."
        case .triggered(.skipped):
            return "Recurring schedule was not triggered because an occurrence is already running."
        case .scheduled(let id, let replaced):
            let prefix: String
            switch action {
            case .notify:
                prefix =
                    replaced
                    ? "Recurring notification replaced."
                    : "Recurring notification scheduled."
            case .promptAgent:
                prefix =
                    replaced
                    ? "Recurring agent task replaced."
                    : "Recurring agent task scheduled."
            case nil:
                fatalError("scheduled result without an action")
            }
            return prefix + " schedule_id: " + id.rawValue + "."
        case .listed(let schedules):
            guard !schedules.isEmpty else {
                return "No active recurring schedules."
            }
            return schedules.map { schedule in
                let nextFireAt = schedule.nextFireAt?.ISO8601Format() ?? "none"
                return [
                    "schedule_id=\(schedule.id.rawValue)",
                    "action=\(schedule.action.kind.rawValue)",
                    "content=\(schedule.action.content)",
                    "next_fire_at=\(nextFireAt)",
                ].joined(separator: " | ")
            }.joined(separator: "\n")
        }
    }

    private func operation(from input: Input) throws -> Schedule.Operation {
        switch input.operation {
        case .cancel:
            return .cancel(id: try scheduleID(from: input))
        case .list:
            return .list(conversationID: try target().conversationID)
        case .trigger:
            return .trigger(id: try scheduleID(from: input))
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
            let id: ScheduleID
            switch input.operation {
            case .create:
                id = ScheduleID(
                    ownerID: target.ownerID,
                    conversationID: target.conversationID,
                    action: action,
                    recurrence: definition.recurrence
                )
            case .replace:
                id = try scheduleID(from: input)
            case .cancel, .list, .trigger:
                fatalError("unreachable")
            }
            switch input.operation {
            case .create:
                return .create(id: id, recurrence: definition.recurrence, request: request)
            case .replace:
                return .replace(id: id, recurrence: definition.recurrence, request: request)
            case .cancel, .list, .trigger:
                fatalError("unreachable")
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
        guard
            let conversationID = ConversationID(
                stableKey: context.agentID.contextID.rawValue
            )
        else {
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
            description:
                "IANA time zone, for example Europe/Berlin. Take it from the location or now tool result, or from memory; never guess it.",
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
