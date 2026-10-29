import Crypto
import DiscoverableActors
import DistributedCluster
import DurableWorkflows
import Hail
import TurgaiDomain
import TurgaiObjects

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What a chat's schedule does each time it's due: says text in the chat, or asks the chat's
/// agent, as a message from whoever made it.
@Describable
public enum WhenDue: Codable, Sendable, Equatable {
    /// Says this text in the chat.
    case say(text: String)
    /// Asks the chat's agent this, which it answers there.
    case ask(instruction: String)
}

/// A chat's schedule: due as its `schedule` says, by the name it was given in the chat, doing
/// `then` there each time, for whoever made it.
public struct ChatSchedule: Codable, Sendable, Equatable {
    public let name: String
    public let schedule: TurgaiObjects.Schedule
    public let then: WhenDue
    /// Who made it: whose message an `ask` is, and who may change it, besides the chat's admins.
    public let ownerID: TurgaiDomain.UserID
    public let conversationID: ConversationID
    public let participantID: ParticipantID
    public let agentDirectoryID: AgentDirectoryID

    public init(
        name: String, schedule: TurgaiObjects.Schedule, then: WhenDue, ownerID: TurgaiDomain.UserID,
        conversationID: ConversationID, agentDirectoryID: AgentDirectoryID = "agent-directory"
    ) {
        self.name = name
        self.schedule = schedule
        self.then = then
        self.ownerID = ownerID
        self.conversationID = conversationID
        self.participantID = ParticipantID(
            channel: conversationID.channel, rawValue: conversationID.externalAddress.rawValue)
        self.agentDirectoryID = agentDirectoryID
    }

    /// The durable schedule named `name` in `conversation`: one for each name in each chat.
    static func id(in conversation: ConversationID, named name: String) -> ScheduleID {
        ScheduleID(
            rawValue: "turgai-schedule-"
                + turgaiDeterministicUUID(conversation.stableKey + "\u{1F}" + name).uuidString)
    }

    /// A connection outage shouldn't silently consume a scheduled delivery: the workflow retries
    /// the activity, and the durable runtime keeps the policy for each occurrence.
    public static let retryPolicy = RetryPolicy(
        initialInterval: .seconds(5),
        backoffCoefficient: 2,
        maximumInterval: .seconds(300),
        maximumAttempts: 6
    )
}

internal func turgaiDeterministicUUID(_ value: String) -> UUID {
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
    public typealias Input = ChatSchedule
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
    private let agentProfiles: TurgaiAgentProfileStore

    public init(agentProfiles: TurgaiAgentProfileStore) {
        self.agentProfiles = agentProfiles
    }

    @Activity
    public func deliver(
        input: ChatSchedule,
        context: ActivityContext
    ) async throws -> DurableVoid {
        try await WhenDue.doing(
            input.then, in: input.conversationID, for: input.ownerID, as: input.participantID,
            directory: input.agentDirectoryID, run: context.workflowID, agentProfiles: agentProfiles,
            on: context.system)
        return DurableVoid()
    }
}

extension WhenDue {
    /// Does `then` in `conversation`, as the run `workflow` of something due there: says its
    /// text, or asks the chat's agent, as a message from `owner`, which the agent that answers the
    /// chat now answers.
    static func doing(
        _ then: WhenDue, in conversation: ConversationID, for owner: TurgaiDomain.UserID,
        as participant: ParticipantID, directory: AgentDirectoryID, run workflow: WorkflowID,
        agentProfiles: TurgaiAgentProfileStore, on system: ClusterSystem
    ) async throws {
        let agentRole = try await TurgaiConnections.agentRole(
            for: conversation, agentProfiles: agentProfiles, on: system)
        let chat = try await Conversation.resolve(
            on: system, conversationID: conversation, agentDirectoryID: directory, agentRole: agentRole,
            memoryExtraction: nil)
        switch then {
        case .say(let text):
            try await chat.notify(text)
        case .ask(let instruction):
            let message = InboundMessage(
                id: MessageID(rawValue: turgaiDeterministicUUID("message:\(workflow.rawValue)")),
                conversationID: conversation, participantID: participant, userID: owner, author: nil,
                text: instruction, receivedAt: Date())
            try await chat.send(
                message, turnID: TurgaiDomain.TurnID(rawValue: turgaiDeterministicUUID("turn:\(workflow.rawValue)")),
                configuration: Conversation.TurnConfiguration(agentRole: agentRole, memoryExtraction: nil))
        }
    }
}
