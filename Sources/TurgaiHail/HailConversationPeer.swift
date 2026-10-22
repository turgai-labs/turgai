import AnyLanguageModel
import DistributedCluster
import Hail
import TurgaiDomain
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct HailResponse: Hashable, Sendable {
    public let reply: ConversationReply

    public var content: String {
        reply.text
    }

    public init?(content: String) {
        guard let reply = ConversationReply(content) else {
            return nil
        }
        self.reply = reply
    }

    public init(reply: ConversationReply) {
        self.reply = reply
    }
}

/// The only Hail input used by the conversation adapter. It carries a
/// Turgai-owned sender identity into Hail without exposing Telegram (or any
/// other channel) types to Hail. What the agent reads is what was said, and its
/// attachments: where things are now is reached through its tools.
struct HailConversationInput: Codable, Sendable {
    let sender: String
    let content: String
    let timestamp: Date
    let inputID: String?

    init(
        sender: String,
        message: InboundMessage
    ) {
        self.sender = sender
        self.timestamp = message.receivedAt
        self.inputID = message.id.rawValue.uuidString

        let attachmentLines = message.attachments.map { attachment in
            var details = "- kind: \(attachment.kind.rawValue)\n  attachment_id: \(attachment.id.rawValue)"
            if let filename = attachment.filename {
                details += "\n  filename: \(filename)"
            }
            if let mimeType = attachment.mimeType {
                details += "\n  mime_type: \(mimeType)"
            }
            return details
        }

        switch (attachmentLines.isEmpty, message.text.isEmpty) {
        case (true, _):
            self.content = message.text
        case (false, true):
            self.content = "Attachments:\n" + attachmentLines.joined(separator: "\n")
        case (false, false):
            self.content =
                message.text
                + "\n\nAttachments:\n"
                + attachmentLines.joined(separator: "\n")
        }
    }

    /// What was said, as the agent's history records it.
    func received() -> AgentHistory.Input {
        AgentHistory.Input(from: .user(id: sender), content: GeneratedContent(content), at: timestamp)
    }
}

/// Hail activity translated into values that can be consumed by the
/// application layer. The Hail `AgentActivity` type stays inside this target.
public enum HailModelEvent: Sendable {
    case started
    case status(String)
    case text(String)
    case reasoning(String)
    /// A tool the model called, with its arguments as the model wrote them.
    case toolCalled(name: String, arguments: String, at: Date)
    /// A tool call's result; `failure` says why it failed, when it did.
    case toolFinished(name: String, output: String, failure: String?, at: Date)
    case usage(inputTokens: Int?, outputTokens: Int?, totalTokens: Int?)
    case contextUsage(usedTokens: Int, limitTokens: Int)
    case compaction(output: GeneratedContent, context: GeneratedContent)
    case completed
}

public enum HailActivityMapper {
    private static func text(_ content: GeneratedContent) -> String {
        if case .string(let value) = content.kind {
            return value
        }
        return content.jsonString
    }

    public static func map(_ activity: AgentActivity) -> [HailModelEvent] {
        switch activity {
        case .turn(.started, _):
            return [.started]
        case .turn(.completed, _):
            return [.completed]
        case .turn(.progress(let progress), let at):
            switch progress {
            case .status(let message):
                return [.status(text(message))]
            case .reasoning(let text):
                return [.reasoning(self.text(text))]
            case .narration(let text):
                return [.text(self.text(text))]
            case .toolCalled(let call):
                return [.toolCalled(name: call.name, arguments: call.arguments.jsonString, at: at)]
            case .toolFinished(let result):
                return [
                    .toolFinished(
                        name: result.name, output: result.output.textRepresentation,
                        failure: result.failureKind?.rawValue, at: at)
                ]
            case .usage(let usage):
                return [
                    .usage(
                        inputTokens: usage.inputTokens,
                        outputTokens: usage.outputTokens,
                        totalTokens: usage.totalTokens
                    )
                ]
            case .contextUsage(let usage):
                return [
                    .contextUsage(
                        usedTokens: usage.usedTokens,
                        limitTokens: usage.limitTokens
                    )
                ]
            case .compaction(let output, let context):
                return [.compaction(output: output, context: context)]
            }
        }
    }
}

/// A typed update from a Hail turn. Structured partial values are cumulative
/// snapshots, like FoundationModels' `PartiallyGenerated` values; consumers
/// replace their current preview rather than append to it.
public enum HailStructuredEvent<Output>: Sendable
where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
    case started
    case partial(Output.PartiallyGenerated)
    case completed(Output)
    case failed(AgentRuntimeError)
}

/// Converts Hail's typed run channel into the small structured boundary that
/// Turgai features can consume without handling every Hail lifecycle event.
public enum HailStructuredUpdateMapper {
    public static func map<Output>(
        _ update: AgentRunEvent<Output>
    ) -> [HailStructuredEvent<Output>]
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
        switch update {
        case .runStarted:
            return [.started]
        case .modelOutputPartialUpdated(let content, _):
            return [.partial(content)]
        case .responseRecorded(let content, _):
            return [.completed(content)]
        case .runFailed(let error, _):
            return [.failed(error)]
        case .received, .modelOutputGenerated, .toolRequested, .toolCompleted,
            .runCompleted:
            return []
        }
    }
}

/// A typed Hail run boundary for features whose model output is a
/// FoundationModels `@Generable` value. Events are delivered through an
/// awaited callback so a slow consumer applies backpressure to the run.
public struct HailStructuredConversationPeer<Output>: Sendable
where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
    public typealias EventHandler = @Sendable (HailStructuredEvent<Output>) async throws -> Void

    private let runHandler:
        @Sendable (
            ConversationTurnRequest,
            @escaping EventHandler
        ) async throws -> Void

    public init(
        run:
            @escaping @Sendable (
                ConversationTurnRequest,
                @escaping EventHandler
            ) async throws -> Void
    ) {
        self.runHandler = run
    }

    public func run(
        to request: ConversationTurnRequest,
        onEvent: @escaping EventHandler
    ) async throws {
        try await runHandler(request, onEvent)
    }
}

/// A small value boundary around one Hail agent. Talking is request and response; listening is
/// the agent's activity stream, which whoever watches subscribes to for as long as it watches.
public struct HailConversationPeer: Sendable {
    public typealias RunHandler = @Sendable (ConversationTurnRequest) async throws -> HailResponse
    public typealias ActivitiesHandler = @Sendable () async throws -> AsyncStream<HailModelEvent>
    public typealias ContextHandler = @Sendable () async throws -> AgentContextSnapshot
    public typealias HistoryHandler = @Sendable () async throws -> AgentHistory
    public typealias DeactivationHandler = @Sendable () async throws -> Void

    private let runHandler: RunHandler
    private let activitiesHandler: ActivitiesHandler
    private let contextHandler: ContextHandler
    private let historyHandler: HistoryHandler
    private let deactivationHandler: DeactivationHandler

    public init(
        run: @escaping RunHandler,
        activities: @escaping ActivitiesHandler = { AsyncStream { $0.finish() } },
        context: @escaping ContextHandler = {
            throw HailAdapterError.contextUnavailable
        },
        history: @escaping HistoryHandler = { AgentHistory() },
        deactivate: @escaping DeactivationHandler = {}
    ) {
        self.runHandler = run
        self.activitiesHandler = activities
        self.contextHandler = context
        self.historyHandler = history
        self.deactivationHandler = deactivate
    }

    /// Asks the agent, and waits for its reply.
    public func run(to request: ConversationTurnRequest) async throws -> HailResponse {
        try await runHandler(request)
    }

    public func respond(to request: ConversationTurnRequest) async throws -> HailResponse {
        try await run(to: request)
    }

    /// What the agent does, as it does it, in any turn: a subscription that lasts until the
    /// stream is no longer consumed, or the agent stops.
    public func activities() async throws -> AsyncStream<HailModelEvent> {
        try await activitiesHandler()
    }

    public func contextSnapshot() async throws -> AgentContextSnapshot {
        try await contextHandler()
    }

    /// The agent's history: its turns since the last compaction, and the summary before them.
    public func history() async throws -> AgentHistory {
        try await historyHandler()
    }

    public func deactivate() async throws {
        try await deactivationHandler()
    }
}

public enum HailAdapterError: Error, Hashable, Sendable {
    case conversationMismatch
    case missingUserMessage
    case activityStreamEnded
    case emptyResponse
    case contextUnavailable
}

private enum HailRunResult: Sendable {
    case response(HailResponse)
    case activityStreamEnded
}

/// Resolves one durable Hail agent per normalized Turgai conversation.
///
/// The adapter owns Hail identity construction and virtual-actor resolution;
/// callers only provide a `ConversationID` and receive `HailConversationPeer`.
public struct HailAgentAdapter: Sendable {
    public let actorSystem: ClusterSystem
    public let agentRole: String

    public init(
        actorSystem: ClusterSystem,
        agentRole: String = "conversation"
    ) {
        self.actorSystem = actorSystem
        self.agentRole = agentRole
    }

    public func peer(
        for conversationID: ConversationID
    ) async throws -> HailConversationPeer {
        return HailConversationPeer(
            run: { request in
                guard request.conversationID == conversationID else {
                    throw HailAdapterError.conversationMismatch
                }
                let message = request.message
                let input = HailConversationInput(
                    sender: message.userID.rawValue,
                    message: message
                )
                let agent = try await self.agent(for: conversationID)
                // Plain chat is a String output. Attachments remain opaque references unless
                // the model explicitly fetches one.
                let response: String = try await agent.respond(
                    input,
                    received: input.received(),
                    inputID: input.inputID
                )
                guard let response = HailResponse(content: response) else {
                    throw HailAdapterError.emptyResponse
                }
                return response
            },
            activities: {
                let agent = try await self.agent(for: conversationID)
                return AsyncStream { continuation in
                    let subscription = Task {
                        for await activity in agent {
                            for event in HailActivityMapper.map(activity) {
                                continuation.yield(event)
                            }
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in subscription.cancel() }
                }
            },
            context: {
                try await self.agent(for: conversationID).contextSnapshot
            },
            history: {
                try await self.agent(for: conversationID).history()
            },
            deactivate: {
                try await self.deactivate(for: conversationID)
            }
        )
    }

    /// Resolves a typed Hail stream for a concrete generated output, including
    /// `@Generable` partial snapshots and the final typed response.
    public func structuredPeer<Output>(
        for conversationID: ConversationID,
        output: Output.Type
    ) async throws -> HailStructuredConversationPeer<Output>
    where Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Codable & Sendable {
        let actorSystem = self.actorSystem

        return HailStructuredConversationPeer(run: { request, onEvent in
            guard request.conversationID == conversationID else {
                throw HailAdapterError.conversationMismatch
            }
            let message = request.message
            let agent = try await self.agent(for: conversationID)

            let input = HailConversationInput(
                sender: message.userID.rawValue,
                message: message
            )

            let agentStream = AgentStream<Output>(actorSystem: actorSystem)
            let updates = agentStream.updates
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await update in updates {
                        for event in HailStructuredUpdateMapper.map(update) {
                            try await onEvent(event)
                        }
                    }
                }
                group.addTask {
                    defer { agentStream.finish() }
                    try await agentStream.send(
                        input,
                        received: input.received(),
                        inputID: input.inputID,
                        to: agent
                    )
                }
                try await group.waitForAll()
            }
        })
    }

    private func agent(for conversationID: ConversationID) async throws -> Agent {
        let agentID = Self.agentID(
            for: conversationID,
            role: agentRole
        )
        return try await actorSystem.agent(agentID)
    }

    public func deactivate(for conversationID: ConversationID) async throws {
        let agent = try await agent(for: conversationID)
        guard try await actorSystem.virtualActors.deactivate(agent) else { return }
    }

    public static func agentID(
        for conversationID: ConversationID,
        role: String = "conversation"
    ) -> AgentID {
        AgentID(
            role: Role(role),
            contextID: AgentContextID(conversationID.stableKey)
        )
    }

    public static func userFacingMessage(for error: any Error) -> String {
        if case let runtimeError as AgentRuntimeError = error {
            switch runtimeError {
            case .modelUnavailable:
                return "I’m having trouble reaching my main systems right now. Please try again in a moment."
            case .modelThoughtPastAnswer:
                return
                    "The model thought for the whole length of an answer without answering, so there's no reply. Ask again, perhaps in a smaller step."
            case .modelMisbehavior(let reason):
                return "The model's answer couldn't be used: \(HailErrorFormatter.sanitizedModelOutput(reason))"
            default:
                break
            }
        }

        if let adapterError = error as? HailAdapterError {
            switch adapterError {
            case .conversationMismatch:
                return "The conversation identity did not match the requested agent."
            case .missingUserMessage:
                return "The model request did not contain a user message."
            case .activityStreamEnded:
                return "The model activity stream ended before the response was available."
            case .emptyResponse:
                return "I couldn’t produce a reply to that message. Please try again."
            case .contextUnavailable:
                return "Context diagnostics are not available for this conversation."
            }
        }
        return HailErrorFormatter.userFacingMessage(error)
    }
}
