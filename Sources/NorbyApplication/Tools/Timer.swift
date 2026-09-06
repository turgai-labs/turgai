import DistributedCluster
import DurableWorkflows
import Foundation
import Hail
import NorbyDomain

/// Durable one-shot timer domain and its scoped capability.
public struct Timer: ScopedEffect, Sendable {
    public let name = "timer"

    public init() {}

    public struct Request: Codable, Sendable {
        public let ownerID: NorbyDomain.UserID
        public let conversationID: ConversationID
        public let participantID: ParticipantID
        public let author: MessageAuthor?
        public let action: DeferredAction
        public let capabilities: ChannelCapabilities
        public let agentDirectoryID: AgentDirectoryID
        public let agentRole: String
        public let snapshotPolicy: AgentSnapshotPolicy

        public init(
            ownerID: NorbyDomain.UserID,
            conversationID: ConversationID,
            participantID: ParticipantID,
            author: MessageAuthor? = nil,
            action: DeferredAction,
            capabilities: ChannelCapabilities = .default,
            agentDirectoryID: AgentDirectoryID = "agent-directory",
            agentRole: String = "conversation",
            snapshotPolicy: AgentSnapshotPolicy = .default
        ) {
            self.ownerID = ownerID
            self.conversationID = conversationID
            self.participantID = participantID
            self.author = author
            self.action = action
            self.capabilities = capabilities
            self.agentDirectoryID = agentDirectoryID
            self.agentRole = agentRole
            self.snapshotPolicy = snapshotPolicy
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

    public enum Error: Swift.Error, Equatable, Sendable {
        case emptyText
    }

    public static let defaultRetryPolicy = Schedule.defaultRetryPolicy

    fileprivate static func start(
        on actorSystem: ClusterSystem,
        id: WorkflowID,
        fireAt: Date,
        request: Request,
        retryPolicy: RetryPolicy? = Self.defaultRetryPolicy
    ) async throws {
        guard !request.action.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.emptyText
        }

        try await actorSystem.workflows.start(
            type: TimerWorkflow.self,
            options: WorkflowOptions(id: id, retryPolicy: retryPolicy),
            input: Input(fireAt: fireAt, request: request)
        )
    }

    public static func cancel(
        on actorSystem: ClusterSystem,
        id: WorkflowID
    ) async throws {
        try await actorSystem.workflows.cancel(
            type: TimerWorkflow.self,
            options: WorkflowOptions(id: id)
        )
    }

    fileprivate static func messageID(for workflowID: WorkflowID) -> MessageID {
        MessageID(rawValue: norbyDeterministicUUID("message:\(workflowID.rawValue)"))
    }

    fileprivate static func turnID(for workflowID: WorkflowID) -> NorbyDomain.TurnID {
        NorbyDomain.TurnID(rawValue: norbyDeterministicUUID("turn:\(workflowID.rawValue)"))
    }
}

extension EffectToken where Effect == Timer {
    public func schedule(
        on actorSystem: ClusterSystem,
        id: WorkflowID,
        fireAt: Date,
        request: Timer.Request,
        retryPolicy: RetryPolicy? = Timer.defaultRetryPolicy
    ) async throws {
        try await Timer.start(
            on: actorSystem,
            id: id,
            fireAt: fireAt,
            request: request,
            retryPolicy: retryPolicy
        )
    }
}

extension WorkflowID {
    /// Stable identity for a one-shot action. The fire date is part of the
    /// identity so moving a timer creates a new workflow rather than trying
    /// to reuse a completed one.
    public init(
        ownerID: NorbyDomain.UserID,
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
        self.init(rawValue: "norby-timer-\(norbyDeterministicUUID(value).uuidString)")
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
            capabilities: input.capabilities,
            agentDirectoryID: input.agentDirectoryID,
            agentRole: input.agentRole,
            snapshotPolicy: input.snapshotPolicy
        )

        switch input.action {
        case .notify(let message):
            try await conversation.notify(message)

        case .promptAgent(let instruction):
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
                turnID: Timer.turnID(for: context.workflowID),
                capabilities: input.capabilities
            )
        }

        return DurableVoid()
    }
}
