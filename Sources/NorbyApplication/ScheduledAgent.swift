import CryptoKit
import DistributedCluster
import DurableWorkflows
import Foundation
import Hail
import NorbyDomain

/// The application boundary for work that wakes a Norby conversation later.
///
/// The workflow itself is deliberately small: scheduling and retry semantics
/// belong to DurableWorkflows, while this activity re-enters Norby's ordinary
/// Conversation boundary. A scheduled run therefore gets the same Hail
/// history, tools, memory and channel delivery as an inbound message.
public enum ScheduledAgent {
    public struct Request: Codable, Sendable {
        public let user: User
        public let conversation: Conversation
        public let ownerID: NorbyDomain.UserID
        public let destination: ConversationID
        public let participantID: ParticipantID
        public let author: MessageAuthor?
        public let text: String
        public let capabilities: ChannelCapabilities

        public init(
            user: User,
            conversation: Conversation,
            ownerID: NorbyDomain.UserID,
            destination: ConversationID,
            participantID: ParticipantID,
            author: MessageAuthor? = nil,
            text: String,
            capabilities: ChannelCapabilities = .default
        ) {
            self.user = user
            self.conversation = conversation
            self.ownerID = ownerID
            self.destination = destination
            self.participantID = participantID
            self.author = author
            self.text = text
            self.capabilities = capabilities
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case emptyPrompt
        case emptyScheduleID
    }

    public static func schedule(
        on actorSystem: ClusterSystem,
        id: ScheduleID,
        recurrence: Calendar.RecurrenceRule,
        request: Request,
        retryPolicy: RetryPolicy? = nil,
        overlapPolicy: ScheduleOverlapPolicy = .skip
    ) async throws {
        guard !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.emptyScheduleID
        }
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.emptyPrompt
        }

        try await actorSystem.workflows.schedule(
            id: id,
            recurrence: recurrence,
            workflow: ScheduledAgentWorkflow.self,
            input: request,
            retryPolicy: retryPolicy,
            overlapPolicy: overlapPolicy
        )
    }

    public static func request(
        on actorSystem: ClusterSystem,
        ownerID: NorbyDomain.UserID,
        destination: ConversationID,
        participantID: ParticipantID,
        author: MessageAuthor? = nil,
            text: String,
            capabilities: ChannelCapabilities = .default,
            agentDirectoryID: AgentDirectoryID = "agent-directory",
        agentRole: String = "conversation",
        snapshotPolicy: AgentSnapshotPolicy = .default
    ) async throws -> Request {
        let user = try await User.resolve(
            on: actorSystem,
            userID: ownerID
        )
        let conversation = try await Conversation.resolve(
            on: actorSystem,
            conversationID: destination,
            capabilities: capabilities,
            agentDirectoryID: agentDirectoryID,
            agentRole: agentRole,
            snapshotPolicy: snapshotPolicy
        )
        return Request(
            user: user,
            conversation: conversation,
            ownerID: ownerID,
            destination: destination,
            participantID: participantID,
            author: author,
            text: text,
            capabilities: capabilities
        )
    }

    public static func cancel(
        on actorSystem: ClusterSystem,
        id: ScheduleID
    ) async throws {
        try await actorSystem.workflows.cancelSchedule(
            id: id,
            workflow: ScheduledAgentWorkflow.self
        )
    }

    public static func describe(
        on actorSystem: ClusterSystem,
        id: ScheduleID
    ) async throws -> ScheduleDescription? {
        try await actorSystem.workflows.describeSchedule(
            id: id,
            workflow: ScheduledAgentWorkflow.self
        )
    }

    public static func timerRequest(
        at date: Date,
        request: Request
    ) -> ScheduledAgentTimerWorkflow.Input {
        ScheduledAgentTimerWorkflow.Input(fireAt: date, request: request)
    }

    fileprivate static func messageID(for workflowID: WorkflowID) -> MessageID {
        MessageID(rawValue: deterministicUUID("message:\(workflowID.rawValue)"))
    }

    fileprivate static func turnID(for workflowID: WorkflowID) -> NorbyDomain.TurnID {
        NorbyDomain.TurnID(rawValue: deterministicUUID("turn:\(workflowID.rawValue)"))
    }

    private static func deterministicUUID(_ value: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}

@Workflow
public struct ScheduledAgentWorkflow {
    public typealias Activities = ScheduledAgentActivities
    public typealias Input = ScheduledAgent.Request
    public typealias Output = DurableVoid

    public init() {}

    public func run(
        input: Input,
        context: WorkflowContext
    ) async throws -> Output {
        try await context.executeActivity(
            ScheduledAgentActivities.Activities.Deliver.self,
            input: input
        )
    }
}

@Workflow
public struct ScheduledAgentTimerWorkflow {
    public typealias Activities = ScheduledAgentActivities
    public typealias Input = ScheduledAgentTimerInput
    public typealias Output = DurableVoid

    public struct ScheduledAgentTimerInput: Codable, Sendable {
        public let fireAt: Date
        public let request: ScheduledAgent.Request

        public init(fireAt: Date, request: ScheduledAgent.Request) {
            self.fireAt = fireAt
            self.request = request
        }
    }

    public init() {}

    public func run(
        input: Input,
        context: WorkflowContext
    ) async throws -> Output {
        try await context.sleep(
            until: input.fireAt,
            summary: "scheduled agent timer"
        )
        return try await context.executeActivity(
            ScheduledAgentActivities.Activities.Deliver.self,
            input: input.request
        )
    }
}

@ActivityContainer
public struct ScheduledAgentActivities {
    @Activity
    public func deliver(
        input: ScheduledAgent.Request,
        context: ActivityContext
    ) async throws -> DurableVoid {
        try await input.user.link(participantID: input.participantID)
        let message = InboundMessage(
            id: ScheduledAgent.messageID(for: context.workflowID),
            conversationID: input.destination,
            participantID: input.participantID,
            userID: input.ownerID,
            author: input.author,
            text: input.text,
            receivedAt: Date()
        )
        try await input.conversation.send(
            message,
            turnID: ScheduledAgent.turnID(for: context.workflowID),
            capabilities: input.capabilities
        )
        return DurableVoid()
    }
}
