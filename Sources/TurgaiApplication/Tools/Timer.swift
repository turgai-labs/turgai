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

/// A chat's timer: due once, at its date, by the name it was given in the chat, doing `then` there
/// for whoever made it.
public struct ChatTimer: Codable, Sendable, Equatable {
    public let name: String
    public let date: Date
    public let then: WhenDue
    /// Who made it: whose message an `ask` is, and who may cancel it, besides the chat's admins.
    public let ownerID: TurgaiDomain.UserID
    public let conversationID: ConversationID
    public let participantID: ParticipantID
    public let agentDirectoryID: AgentDirectoryID

    public init(
        name: String, date: Date, then: WhenDue, ownerID: TurgaiDomain.UserID, conversationID: ConversationID,
        agentDirectoryID: AgentDirectoryID = "agent-directory"
    ) {
        self.name = name
        self.date = date
        self.then = then
        self.ownerID = ownerID
        self.conversationID = conversationID
        self.participantID = ParticipantID(channel: conversationID.channel, rawValue: ownerID.key)
        self.agentDirectoryID = agentDirectoryID
    }

    /// The durable timer named `name` in `conversation` for `date`: one for each date it's set to,
    /// which is due once, however often it's started.
    static func id(in conversation: ConversationID, named name: String, at date: Date) -> WorkflowID {
        WorkflowID(
            rawValue: "turgai-timer-"
                + turgaiDeterministicUUID(
                    conversation.stableKey + "\u{1F}" + name + "\u{1F}" + String(Int(date.timeIntervalSince1970))
                ).uuidString)
    }
}

/// A chat's timer, kept durably: when it's due, it does what it says in the chat, once.
@Workflow
public struct TimerWorkflow {
    public typealias Activities = TimerActivities
    public typealias Input = ChatTimer
    public typealias Output = DurableVoid

    public init() {}

    public func run(input: Input, context: WorkflowContext) async throws -> Output {
        try await context.sleep(until: input.date, summary: "timer")
        return try await context.executeActivity(TimerActivities.Activities.Deliver.self, input: input)
    }
}

@ActivityContainer
public struct TimerActivities {
    private let agentProfiles: TurgaiAgentProfileStore

    public init(agentProfiles: TurgaiAgentProfileStore) {
        self.agentProfiles = agentProfiles
    }

    @Activity
    public func deliver(input: ChatTimer, context: ActivityContext) async throws -> DurableVoid {
        try await WhenDue.doing(
            input.then, in: input.conversationID, for: input.ownerID, as: input.participantID,
            directory: input.agentDirectoryID, run: context.workflowID, agentProfiles: agentProfiles,
            on: context.system)
        // Due once: done, it isn't a timer any more.
        let chat = try await Conversation.resolve(
            on: context.system, conversationID: input.conversationID, agentDirectoryID: input.agentDirectoryID)
        if let space = try await chat.spaceID {
            await context.system.tellTasks(in: space, .ended(.timer(context.workflowID)))
        }
        return DurableVoid()
    }
}
