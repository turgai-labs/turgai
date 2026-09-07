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
public struct Schedule: ScopedEffect, Sendable {
    public typealias Output = Result

    public let name = "schedule"
    public let operation: Operation

    public enum Operation: Sendable {
        case create(
            id: ScheduleID,
            recurrence: Calendar.RecurrenceRule,
            request: Request
        )
        case replace(
            id: ScheduleID,
            recurrence: Calendar.RecurrenceRule,
            request: Request
        )
        case cancel(id: ScheduleID)
        case list(conversationID: ConversationID)
        case trigger(id: ScheduleID)
    }

    public enum Result: Sendable {
        case scheduled(id: ScheduleID, replaced: Bool)
        case cancelled
        case listed([Info])
        case triggered(ScheduleTriggerOutcome)
    }

    public init(operation: Operation) {
        self.operation = operation
    }

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

    public struct Info: Sendable {
        public let id: ScheduleID
        public let recurrence: Calendar.RecurrenceRule
        public let action: DeferredAction
        public let createdAt: Date
        public let lastFiredAt: Date?
        public let nextFireAt: Date?
        public let nextFireIn: Duration?
        public let executions: [ScheduleExecutionState]

        public init(
            id: ScheduleID,
            recurrence: Calendar.RecurrenceRule,
            action: DeferredAction,
            createdAt: Date,
            lastFiredAt: Date?,
            nextFireAt: Date?,
            nextFireIn: Duration?,
            executions: [ScheduleExecutionState]
        ) {
            self.id = id
            self.recurrence = recurrence
            self.action = action
            self.createdAt = createdAt
            self.lastFiredAt = lastFiredAt
            self.nextFireAt = nextFireAt
            self.nextFireIn = nextFireIn
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

    public static func run(
        in token: borrowing EffectToken<Schedule>
    ) async throws -> Result {
        let workflows = ActorSystemDependency.current.workflows
        let operation = token.withConfiguration { $0.operation }

        switch operation {
        case .cancel(let id):
            try await cancel(id, workflows: workflows)
            return .cancelled

        case .list(let conversationID):
            return .listed(
                try await list(
                    conversationID: conversationID,
                    workflows: workflows
                )
            )

        case .trigger(let id):
            return .triggered(
                try await trigger(id, workflows: workflows)
            )

        case .create(let id, let recurrence, let request),
            .replace(let id, let recurrence, let request):
            let replaced: Bool
            switch operation {
            case .create:
                replaced = false
            case .replace:
                try await cancel(id, workflows: workflows)
                replaced = true
            case .cancel, .list, .trigger:
                fatalError("unreachable")
            }
            try await schedule(
                id: id,
                recurrence: recurrence,
                request: request,
                workflows: workflows
            )
            return .scheduled(id: id, replaced: replaced)
        }
    }

    private static func schedule(
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

    private static func cancel(
        _ id: ScheduleID,
        workflows: WorkflowActions
    ) async throws {
        try await workflows.cancelSchedule(id)
    }

    private static func trigger(
        _ id: ScheduleID,
        workflows: WorkflowActions
    ) async throws -> ScheduleTriggerOutcome {
        try await workflows.triggerSchedule(id)
    }

    private static func list(
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
