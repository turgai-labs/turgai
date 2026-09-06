import DistributedCluster
import DurableWorkflows
import Foundation
import Hail
import NorbyDomain

/// Creates a durable one-shot action for the current conversation.
public struct TimerTool: Tool {
    public typealias Effect = CombinedEffect<ClockEffect, Timer>

    public struct Input: Codable, Sendable {
        public let action: DeferredAction.Kind
        public let message: String?
        public let instruction: String?
        public let delaySeconds: Int

        private enum CodingKeys: String, CodingKey {
            case action
            case message
            case instruction
            case delaySeconds = "delay_seconds"
        }

        public init(
            action: DeferredAction.Kind,
            message: String? = nil,
            instruction: String? = nil,
            delaySeconds: Int
        ) {
            self.action = action
            self.message = message
            self.instruction = instruction
            self.delaySeconds = delaySeconds
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case missingMessage
        case emptyMessage
        case missingInstruction
        case emptyInstruction
        case invalidDelay(Int)
        case invalidConversationID(String)
        case invalidParticipantID(String)
    }

    public let name = "timer"
    public let description =
        "Create a durable one-shot action for this conversation. Use notify when the future result is a user-visible message, whether the user says 'remind' or 'notify'. Use prompt_agent when Norby should wake up, use its tools, and compose a fresh response. delay_seconds is the time from now until the action fires."

    private let actorSystem: ClusterSystem
    private let context: AgentTurnContext
    private let snapshotPolicy: AgentSnapshotPolicy
    private let clock: @Sendable () -> Date

    public init(
        actorSystem: ClusterSystem,
        context: AgentTurnContext,
        snapshotPolicy: AgentSnapshotPolicy = .default,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.actorSystem = actorSystem
        self.context = context
        self.snapshotPolicy = snapshotPolicy
        self.clock = clock
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
                        "action": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "notify sends a message to the user; prompt_agent starts a future agent turn.",
                            enumValues: ["notify", "prompt_agent"]
                        ),
                        "message": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "Required for notify. The final user-visible message to send when the timer fires, without describing the timer or scheduling operation.",
                            enumValues: nil
                        ),
                        "instruction": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "Required for prompt_agent. The complete request to give Norby when the timer fires.",
                            enumValues: nil
                        ),
                        "delay_seconds": LLMToolSchema.PropertySchema(
                            type: "integer",
                            description: "Positive number of seconds from now until the action fires.",
                            enumValues: nil
                        ),
                    ],
                    required: ["action", "delay_seconds"]
                )
            )
        )
    }

    public func effect(for input: Input) throws -> Effect {
        try validate(input)
        return ClockEffect(now: clock)
            .combined(
                with: Timer()
            )
    }

    public func execute(
        input: Input,
        token: borrowing EffectToken<Effect>
    ) async throws -> String {
        try validate(input)
        let now = await token.withLeft { clock in
            clock.now()
        }

        return try await token.withRight { timer in
            let target = try self.target()
            let action = try deferredAction(from: input)
            let request = Timer.Request(
                ownerID: target.ownerID,
                conversationID: target.conversationID,
                participantID: target.participantID,
                action: action,
                snapshotPolicy: self.snapshotPolicy
            )
            let fireAt = now.addingTimeInterval(TimeInterval(input.delaySeconds))
            let workflowID = WorkflowID(
                ownerID: target.ownerID,
                conversationID: target.conversationID,
                action: action,
                fireAt: fireAt
            )
            try await timer.schedule(
                on: self.actorSystem,
                id: workflowID,
                fireAt: fireAt,
                request: request
            )

            switch input.action {
            case .notify:
                return "Notification scheduled."
            case .promptAgent:
                return "One-shot agent task scheduled."
            }
        }
    }

    private func validate(_ input: Input) throws {
        switch input.action {
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
        guard input.delaySeconds > 0 else {
            throw Error.invalidDelay(input.delaySeconds)
        }
    }

    private func deferredAction(from input: Input) throws -> DeferredAction {
        switch input.action {
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
