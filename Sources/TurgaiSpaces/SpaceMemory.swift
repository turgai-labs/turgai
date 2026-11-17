import Distributed
import DistributedCluster
import DurableWorkflows
import Hail
import TurgaiConversations
import TurgaiDomain
import TurgaiHail
import TurgaiMemory
import TurgaiPeople

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// An exchange one of a space's conversations heard, read into its person's memory once they've
/// been quiet there: with the model of the bot that heard it, as the space has it then.
public struct HeardExchange: Codable, Sendable, Equatable {
    public let space: SpaceID
    public let conversation: ConversationID
    public let person: TurgaiDomain.UserID
    public let bot: BotID
    /// The exchange: the latest in the conversation when it was heard.
    public let exchange: MemorySourceID
    /// Its message's id in the channel it came through: where it's marked once something's noted.
    public let channelMessageID: ChannelMessageID?
    /// When it's read, unless something's said after it: then the later one reads it with the rest.
    public let due: Date

    /// Long enough for a follow-up exchange to be read with the one before.
    static let quietPeriod: TimeInterval = 240

    /// The read of `heard`, `person`'s, in the conversation `conversation` of `space`.
    init(_ heard: MemoryObservation, of person: TurgaiDomain.UserID, in conversation: ConversationID, of space: SpaceID)
    {
        self.space = space
        self.conversation = conversation
        self.person = person
        self.bot = heard.heardBy
        self.exchange = heard.sourceID
        self.channelMessageID = heard.channelMessageID
        self.due = heard.observedAt.addingTimeInterval(Self.quietPeriod)
    }

    /// One read for each exchange: heard again, it's the same read.
    var id: WorkflowID {
        WorkflowID(rawValue: "turgai-memory-read-\(person.key)-\(exchange.rawValue.uuidString)")
    }

    /// A failed read is tried again, a while longer each time.
    static let retryPolicy = RetryPolicy(
        initialInterval: .seconds(5), backoffCoefficient: 2, maximumInterval: .seconds(80), maximumAttempts: 6)
}

/// A heard exchange, read once its person has been quiet: a newer exchange in the conversation
/// makes it stale, and the newer one's read takes it in.
@Workflow
public struct MemoryReadWorkflow {
    public typealias Activities = MemoryReadActivities
    public typealias Input = HeardExchange
    public typealias Output = DurableVoid

    public init() {}

    public func run(input: Input, context: WorkflowContext) async throws -> Output {
        try await context.sleep(until: input.due, summary: "quiet")
        return try await context.executeActivity(MemoryReadActivities.Activities.Read.self, input: input)
    }
}

@ActivityContainer
public struct MemoryReadActivities {
    public init() {}

    /// Reads `input` into its person's memory with the model of the bot that heard it: the
    /// exchange is marked in its conversation when something was noted.
    @Activity
    public func read(input: HeardExchange, context: ActivityContext) async throws -> DurableVoid {
        let system = context.system
        let agentID = HailAgentAdapter.agentID(for: input.conversation, in: input.space, role: input.bot.role)
        let model = try await system.agentRuntime.modelConfiguration(for: agentID).model
        let endpoint = try await system.agentRuntime.endpoint(for: model.identifier, agentID: agentID)
        let outcome = try await MemoryExtractionService.extractAndCommit(
            endpoint: endpoint, actorSystem: system, user: try await User.identified(by: input.person, on: system),
            conversation: input.conversation, expectedLatestSourceID: input.exchange)
        guard case .committed(let changes, _) = outcome, !changes.isEmpty else { return DurableVoid() }
        try await Space.identified(by: input.space, on: system).noted(
            NotedMessage(id: MessageID(rawValue: input.exchange.rawValue), channelID: input.channelMessageID),
            in: input.conversation)
        return DurableVoid()
    }
}

extension Space {
    /// `exchange`, `person`'s, heard in its conversation `conversation`: read into their memory once
    /// they've been quiet, durably.
    public distributed func heard(
        _ exchange: MemoryObservation, of person: TurgaiDomain.UserID, in conversation: ConversationID
    ) async throws {
        let read = HeardExchange(exchange, of: person, in: conversation, of: try made().id)
        try await actorSystem.workflows.start(
            type: MemoryReadWorkflow.self,
            options: WorkflowOptions(id: read.id, retryPolicy: HeardExchange.retryPolicy),
            input: read)
    }
}
