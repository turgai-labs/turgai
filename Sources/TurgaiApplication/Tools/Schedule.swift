import Crypto
import DiscoverableActors
import DistributedCluster
import DurableWorkflows
import Hail
import TurgaiDomain
import TurgaiObjects
import TurgaiSpaces

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
    /// The space whose chat it's in, which it does what it does through.
    public let space: SpaceID
    public let conversationID: ConversationID
    public let participantID: ParticipantID

    public init(
        name: String, schedule: TurgaiObjects.Schedule, then: WhenDue, ownerID: TurgaiDomain.UserID,
        in space: SpaceID, conversationID: ConversationID
    ) {
        self.name = name
        self.schedule = schedule
        self.then = then
        self.ownerID = ownerID
        self.space = space
        self.conversationID = conversationID
        self.participantID = ParticipantID(channel: conversationID.channel, rawValue: ownerID.key)
    }

    /// The durable schedule named `name` in `conversation` of `space`: one for each name in each
    /// chat.
    static func id(in conversation: ConversationID, of space: SpaceID, named name: String) -> ScheduleID {
        ScheduleID(
            rawValue: "turgai-schedule-"
                + turgaiDeterministicUUID(
                    space.rawValue.uuidString + "/" + conversation.stableKey + "\u{1F}" + name
                ).uuidString)
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
    public init() {}

    @Activity
    public func deliver(
        input: ChatSchedule,
        context: ActivityContext
    ) async throws -> DurableVoid {
        try await WhenDue.doing(
            input.then, in: input.conversationID, of: input.space, for: input.ownerID, as: input.participantID,
            run: context.workflowID, on: context.system)
        return DurableVoid()
    }
}

extension WhenDue {
    /// What it does, as a person reads it: `says …`, `asks …`.
    var described: String {
        switch self {
        case .say(let text): "says \(text)"
        case .ask(let instruction): "asks \(instruction)"
        }
    }

    /// Does `then` in `conversation`, through its space `space`, as the run `workflow` of
    /// something due there: says its text, or asks the chat's bot, as a message from `owner`.
    static func doing(
        _ then: WhenDue, in conversation: ConversationID, of space: SpaceID, for owner: TurgaiDomain.UserID,
        as participant: ParticipantID, run workflow: WorkflowID, on system: ClusterSystem
    ) async throws {
        let space = try await Space.identified(by: space, on: system)
        switch then {
        case .say(let text):
            try await space.notify(conversation, text)
        case .ask(let instruction):
            let message = InboundMessage(
                id: MessageID(rawValue: turgaiDeterministicUUID("message:\(workflow.rawValue)")),
                conversationID: conversation, participantID: participant, userID: owner, author: nil,
                text: instruction, receivedAt: Date())
            try await space.say(
                message, turnID: TurgaiDomain.TurnID(rawValue: turgaiDeterministicUUID("turn:\(workflow.rawValue)")))
        }
    }
}

extension KeptTask {
    /// `schedule`, a chat's, kept as `id`: paused, or not.
    public init(_ schedule: ChatSchedule, id: ScheduleID, paused: Bool) {
        self.init(
            id: .schedule(id), of: .chat(schedule.conversationID, name: schedule.name, does: schedule.then.described),
            due: .schedule(schedule.schedule), paused: paused, maker: schedule.ownerID)
    }

    /// `timer`, a chat's, kept as `id`.
    public init(_ timer: ChatTimer, id: WorkflowID) {
        self.init(
            id: .timer(id), of: .chat(timer.conversationID, name: timer.name, does: timer.then.described),
            due: .timer(.at(timer.date)), paused: false, maker: timer.ownerID)
    }
}
