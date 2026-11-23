import AttributedCalls
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

/// A chat's timer: due once, at its date, by the name it was given in the chat, doing `then` there.
/// It's the chat's: whoever is in the chat may change it.
public struct ChatTimer: Codable, Sendable, Equatable {
    public let name: String
    public let date: Date
    public let then: WhenDue
    /// Who asked for it: whom the bot answers when it's due and asks the bot something.
    public let askedBy: Party
    /// The space whose chat it's in, which it does what it does through.
    public let space: SpaceID
    public let conversationID: ConversationID

    public init(
        name: String, date: Date, then: WhenDue, askedBy: Party, in space: SpaceID, conversationID: ConversationID
    ) {
        self.name = name
        self.date = date
        self.then = then
        self.askedBy = askedBy
        self.space = space
        self.conversationID = conversationID
    }

    /// The durable timer named `name` in `conversation` of `space` for `date`: one for each date
    /// it's set to, which is due once, however often it's started.
    static func id(in conversation: ConversationID, of space: SpaceID, named name: String, at date: Date)
        -> WorkflowID
    {
        WorkflowID(
            rawValue: "turgai-timer-"
                + turgaiDeterministicUUID(
                    space.rawValue.uuidString + "/" + conversation.stableKey + "\u{1F}" + name + "\u{1F}"
                        + String(Int(date.timeIntervalSince1970))
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
    public init() {}

    @Activity
    public func deliver(input: ChatTimer, context: ActivityContext) async throws -> DurableVoid {
        // What's due is the space's timers' own work, as a reminder is its actor's.
        try await Call.asWork(of: .owned(by: input.space, "builtin", "timers")) {
            try await WhenDue.doing(
                input.then, for: input.askedBy, in: input.conversationID, of: input.space, run: context.workflowID,
                on: context.system)
            // Due once: done, it isn't a timer any more.
            await context.system.tellTasks(in: input.space, .ended(.timer(context.workflowID)))
        }
        return DurableVoid()
    }
}
