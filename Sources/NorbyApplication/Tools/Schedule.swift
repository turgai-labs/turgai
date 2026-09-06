import CryptoKit
import DistributedCluster
import DurableWorkflows
import Foundation
import Hail
import NorbyDomain

/// Durable recurring schedule domain and its scoped capability.
public struct Schedule: ScopedEffect, Sendable {
    public let name = "schedule"

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

    public enum Error: Swift.Error, Equatable, Sendable {
        case emptyText
        case emptyScheduleID
        case invalidConversationID(String)
        case invalidParticipantID(String)
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

    fileprivate static func schedule(
        on actorSystem: ClusterSystem,
        id: ScheduleID,
        recurrence: Calendar.RecurrenceRule,
        request: Request,
        retryPolicy: RetryPolicy? = Self.defaultRetryPolicy,
        overlapPolicy: ScheduleOverlapPolicy = .skip
    ) async throws {
        guard !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.emptyScheduleID
        }
        guard !request.action.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.emptyText
        }

        try await actorSystem.workflows.schedule(
            id: id,
            recurrence: recurrence,
            workflow: ScheduleWorkflow.self,
            input: request,
            retryPolicy: retryPolicy,
            overlapPolicy: overlapPolicy
        )
    }

    fileprivate static func cancel(
        on actorSystem: ClusterSystem,
        id: ScheduleID
    ) async throws {
        try await actorSystem.workflows.cancelSchedule(
            id: id,
            workflow: ScheduleWorkflow.self
        )
    }

    fileprivate static func describe(
        on actorSystem: ClusterSystem,
        id: ScheduleID
    ) async throws -> ScheduleDescription? {
        try await actorSystem.workflows.describeSchedule(
            id: id,
            workflow: ScheduleWorkflow.self
        )
    }

    fileprivate static func messageID(for workflowID: WorkflowID) -> MessageID {
        MessageID(rawValue: norbyDeterministicUUID("message:\(workflowID.rawValue)"))
    }

    fileprivate static func turnID(for workflowID: WorkflowID) -> NorbyDomain.TurnID {
        NorbyDomain.TurnID(rawValue: norbyDeterministicUUID("turn:\(workflowID.rawValue)"))
    }
}

extension EffectToken where Effect == Schedule {
    public func schedule(
        on actorSystem: ClusterSystem,
        id: ScheduleID,
        recurrence: Calendar.RecurrenceRule,
        request: Schedule.Request,
        retryPolicy: RetryPolicy? = Schedule.defaultRetryPolicy,
        overlapPolicy: ScheduleOverlapPolicy = .skip
    ) async throws {
        try await Schedule.schedule(
            on: actorSystem,
            id: id,
            recurrence: recurrence,
            request: request,
            retryPolicy: retryPolicy,
            overlapPolicy: overlapPolicy
        )
    }

    public func cancel(
        on actorSystem: ClusterSystem,
        id: ScheduleID
    ) async throws {
        try await Schedule.cancel(on: actorSystem, id: id)
    }

    public func describe(
        on actorSystem: ClusterSystem,
        id: ScheduleID
    ) async throws -> ScheduleDescription? {
        try await Schedule.describe(on: actorSystem, id: id)
    }
}

/// Stable identity for one recurring action in one conversation. Calling the
/// tool again with the same action and recurrence addresses the same durable
/// schedule instead of creating a duplicate.
extension ScheduleID {
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
        self.init(rawValue: "norby-schedule-\(norbyDeterministicUUID(value).uuidString)")
    }
}

internal func norbyDeterministicUUID(_ value: String) -> UUID {
    let digest = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
    return UUID(uuid: (
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
                turnID: Schedule.turnID(for: context.workflowID),
                capabilities: input.capabilities
            )
        }

        return DurableVoid()
    }
}
