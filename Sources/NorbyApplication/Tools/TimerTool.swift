import DurableWorkflows
import Hail
import NorbyDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Creates a durable one-shot action for the current conversation.
public struct TimerTool: Tool {
    public typealias Effect = Timer

    public enum Operation: String, Codable, Sendable, Equatable {
        case create
        case replace
        case cancel
        case list
    }

    public struct Input: Codable, Sendable {
        public let operation: Operation
        public let timerID: String?
        public let action: DeferredAction.Kind?
        public let message: String?
        public let instruction: String?
        public let trigger: Timer.Trigger?

        private enum CodingKeys: String, CodingKey {
            case operation
            case timerID = "timer_id"
            case action
            case message
            case instruction
            case trigger
        }

        public init(
            operation: Operation = .create,
            timerID: String? = nil,
            action: DeferredAction.Kind? = nil,
            message: String? = nil,
            instruction: String? = nil,
            trigger: Timer.Trigger? = nil
        ) {
            self.operation = operation
            self.timerID = timerID
            self.action = action
            self.message = message
            self.instruction = instruction
            self.trigger = trigger
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case missingMessage
        case emptyMessage
        case missingAction
        case missingInstruction
        case emptyInstruction
        case missingTimerID
        case emptyTimerID
        case missingTrigger
        case invalidConversationID(String)
        case invalidParticipantID(String)
    }

    public let name = "timer"
    public let description =
        "Manage durable one-shot actions for this conversation. Use create for a new timer, replace with its timer_id to change it, cancel to remove it, or list to inspect active timers. Use notify when the future result is a user-visible message and prompt_agent when Norby should wake up, use its tools, and compose a fresh response. For create and replace, trigger is either after with an amount and unit, or at with calendar components and an explicit IANA time_zone. Use after for relative requests such as in five minutes. Use at for calendar requests such as at 17:30 or on Saturday at 09:00. Do not put an absolute date into after."

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
                            description: "The operation: create, replace, cancel, or list.",
                            enumValues: ["create", "replace", "cancel", "list"]
                        ),
                        "timer_id": LLMToolSchema.PropertySchema(
                            type: "string",
                            description:
                                "The opaque timer_id returned when the timer was created. Required for replace and cancel.",
                            enumValues: nil
                        ),
                        "action": LLMToolSchema.PropertySchema(
                            type: "string",
                            description:
                                "Required for create and replace. notify sends a message to the user; prompt_agent starts a future agent turn.",
                            enumValues: ["notify", "prompt_agent"]
                        ),
                        "message": LLMToolSchema.PropertySchema(
                            type: "string",
                            description:
                                "Required for notify actions. The final user-visible message to send when the timer fires, without describing the timer or scheduling operation.",
                            enumValues: nil
                        ),
                        "instruction": LLMToolSchema.PropertySchema(
                            type: "string",
                            description:
                                "Required for prompt_agent actions. The complete request to give Norby when the timer fires.",
                            enumValues: nil
                        ),
                        "trigger": TimerToolSchema.trigger,
                    ],
                    required: ["operation"]
                )
            )
        )
    }

    public func effect(for input: Input) throws -> Effect {
        try validate(input)
        let target = try target()
        switch input.operation {
        case .cancel:
            return Timer(
                operation: .cancel(id: try timerID(from: input))
            )
        case .list:
            return Timer(
                operation: .list(conversationID: target.conversationID)
            )
        case .create, .replace:
            let action = try deferredAction(from: input)
            guard let trigger = input.trigger else {
                throw Error.missingTrigger
            }
            let request = Timer.Request(
                ownerID: target.ownerID,
                conversationID: target.conversationID,
                participantID: target.participantID,
                action: action,
                snapshotPolicy: self.snapshotPolicy
            )
            switch input.operation {
            case .create:
                return Timer(
                    operation: .create(trigger: trigger, request: request)
                )
            case .replace:
                return Timer(
                    operation: .replace(
                        id: try timerID(from: input),
                        trigger: trigger,
                        request: request
                    )
                )
            case .cancel, .list:
                fatalError("unreachable")
            }
        }
    }

    public func run(
        input: Input,
        token: borrowing EffectToken<Effect>
    ) async throws -> String {
        try validate(input)
        let result = try await Timer.run(in: token)
        return render(result)
    }

    private func validate(_ input: Input) throws {
        switch input.operation {
        case .cancel:
            _ = try timerID(from: input)
        case .list:
            break
        case .create, .replace:
            if input.operation == .replace {
                _ = try timerID(from: input)
            }
            guard let action = input.action else {
                throw Error.missingAction
            }
            switch action {
            case .notify:
                guard let message = input.message else { throw Error.missingMessage }
                guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Error.emptyMessage
                }
            case .promptAgent:
                guard let instruction = input.instruction else { throw Error.missingInstruction }
                guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Error.emptyInstruction
                }
            }
            guard let trigger = input.trigger else {
                throw Error.missingTrigger
            }
            try Timer.validate(trigger)
        }
    }

    private func render(_ result: Timer.Result) -> String {
        switch result {
        case .cancelled:
            return "One-shot timer cancelled."
        case .scheduled(let id, let action, let fireAt, let timeZone, let replaced):
            let prefix: String
            switch action {
            case .notify:
                prefix =
                    replaced
                    ? "One-shot notification replaced."
                    : "One-shot notification scheduled."
            case .promptAgent:
                prefix =
                    replaced
                    ? "One-shot agent task replaced."
                    : "One-shot agent task scheduled."
            }
            let zone = timeZone.map { " \($0)" } ?? ""
            return "\(prefix) fire_at=\(fireAt.ISO8601Format())\(zone), timer_id=\(id.rawValue)."
        case .listed(let timers):
            guard !timers.isEmpty else {
                return "No active one-shot timers."
            }
            return timers.map { timer in
                [
                    "timer_id=\(timer.id.rawValue)",
                    "action=\(timer.action.kind.rawValue)",
                    "content=\(timer.action.content)",
                    "fire_at=\(timer.fireAt.ISO8601Format())",
                ].joined(separator: " | ")
            }.joined(separator: "\n")
        }
    }

    private func timerID(from input: Input) throws -> WorkflowID {
        guard let rawValue = input.timerID else {
            throw Error.missingTimerID
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Error.emptyTimerID
        }
        return WorkflowID(rawValue: trimmed)
    }

    private func deferredAction(from input: Input) throws -> DeferredAction {
        guard let action = input.action else {
            throw Error.missingAction
        }
        switch action {
        case .notify:
            guard let message = input.message else { throw Error.missingMessage }
            return .notify(message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        case .promptAgent:
            guard let instruction = input.instruction else { throw Error.missingInstruction }
            return .promptAgent(instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines))
        }
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

private enum TimerToolSchema {
    static let calendarComponents = LLMToolSchema.PropertySchema(
        type: "object",
        description: "Calendar components such as day, hour, minute, weekday, month, or year.",
        enumValues: nil,
        properties: [
            "era": LLMToolSchema.PropertySchema(
                type: "integer",
                description: "Calendar era.",
                enumValues: nil
            ),
            "year": LLMToolSchema.PropertySchema(
                type: "integer",
                description: "Calendar year.",
                enumValues: nil
            ),
            "month": LLMToolSchema.PropertySchema(
                type: "integer",
                description: "Month number from 1 through 12.",
                enumValues: nil
            ),
            "day": LLMToolSchema.PropertySchema(
                type: "integer",
                description: "Day of month.",
                enumValues: nil
            ),
            "hour": LLMToolSchema.PropertySchema(
                type: "integer",
                description: "Local hour from 0 through 23.",
                enumValues: nil
            ),
            "minute": LLMToolSchema.PropertySchema(
                type: "integer",
                description: "Minute from 0 through 59.",
                enumValues: nil
            ),
            "second": LLMToolSchema.PropertySchema(
                type: "integer",
                description: "Second from 0 through 59.",
                enumValues: nil
            ),
            "nanosecond": LLMToolSchema.PropertySchema(
                type: "integer",
                description: "Nanosecond from 0 through 999999999.",
                enumValues: nil
            ),
            "weekday": LLMToolSchema.PropertySchema(
                type: "integer",
                description: "Weekday number: Sunday is 1 and Saturday is 7.",
                enumValues: nil
            ),
            "weekday_ordinal": LLMToolSchema.PropertySchema(
                type: "integer",
                description: "Ordinal occurrence of a weekday in a month.",
                enumValues: nil
            ),
            "quarter": LLMToolSchema.PropertySchema(
                type: "integer",
                description: "Quarter number from 1 through 4.",
                enumValues: nil
            ),
            "week_of_month": LLMToolSchema.PropertySchema(
                type: "integer",
                description: "Week number within the month.",
                enumValues: nil
            ),
            "week_of_year": LLMToolSchema.PropertySchema(
                type: "integer",
                description: "Week number within the year.",
                enumValues: nil
            ),
            "year_for_week_of_year": LLMToolSchema.PropertySchema(
                type: "integer",
                description: "Year associated with week_of_year.",
                enumValues: nil
            ),
        ],
        required: []
    )

    static let trigger = LLMToolSchema.PropertySchema(
        type: "object",
        description: "When the one-shot action fires. Use after for elapsed time, or occurrence for a calendar time.",
        enumValues: nil,
        properties: [
            "kind": LLMToolSchema.PropertySchema(
                type: "string",
                description: "The trigger form.",
                enumValues: ["after", "at"]
            ),
            "amount": LLMToolSchema.PropertySchema(
                type: "integer",
                description: "Positive amount for an after trigger.",
                enumValues: nil
            ),
            "unit": LLMToolSchema.PropertySchema(
                type: "string",
                description: "Unit for an after trigger.",
                enumValues: ["seconds", "minutes", "hours", "days", "weeks"]
            ),
            "at": LLMToolSchema.PropertySchema(
                type: "object",
                description:
                    "A calendar occurrence. components selects the next matching date and time in time_zone. Do not use relative offsets here.",
                enumValues: nil,
                properties: [
                    "components": calendarComponents,
                    "time_zone": LLMToolSchema.PropertySchema(
                        type: "string",
                        description:
                            "Required IANA timezone, for example Europe/Berlin. Take it from the location or now tool result, or from memory; never guess it.",
                        enumValues: nil
                    ),
                ],
                required: ["components", "time_zone"]
            ),
        ],
        required: ["kind"]
    )
}
