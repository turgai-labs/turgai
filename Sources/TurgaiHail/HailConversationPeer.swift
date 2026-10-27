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

/// What a conversation's agent replies with.
@Generable
public struct AgentReply: Codable, Sendable {
    /// What the assistant says back.
    public let text: String
}

extension AgentReply.PartiallyGenerated: Codable {}

public struct HailResponse: Hashable, Sendable {
    public let reply: ConversationReply

    public var content: String {
        reply.text
    }

    /// The agent's reply, which says something: an empty one is an error.
    public init(_ reply: AgentReply) throws(HailAdapterError) {
        guard let reply = ConversationReply(reply.text) else {
            throw .emptyResponse
        }
        self.reply = reply
    }

    public init(reply: ConversationReply) {
        self.reply = reply
    }
}

/// The only Hail input used by the conversation adapter, without Telegram (or any
/// other channel) types. What the agent reads is what was said, and its
/// attachments: where things are now is reached through its tools.
struct HailConversationInput: ConvertibleToGeneratedContent, Codable, Sendable {
    let content: String

    init(message: InboundMessage) {
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

    var generatedContent: GeneratedContent { GeneratedContent(content) }
}

/// What an agent does in a turn, translated into values that can be consumed by the application
/// layer. Hail's own run events stay inside this target.
public enum HailModelEvent: Sendable {
    case started
    case status(String)
    /// The reply so far, whole: it replaces what was shown before.
    case reply(String)
    case reasoning(String)
    /// A tool the model called, with its arguments as the model wrote them.
    case toolCalled(name: String, arguments: String, at: Date)
    /// A tool call's result; `failure` says why it failed, when it did.
    case toolFinished(name: String, output: String, failure: String?, at: Date)
    case completed
}

public enum HailRunMapper {
    private static func text(_ content: GeneratedContent) -> String {
        if case .string(let value) = content.kind {
            return value
        }
        return content.jsonString
    }

    /// What the agent did in a turn, as the turn's call brought it back.
    public static func map(_ update: AgentRunEvent<AgentReply>) -> [HailModelEvent] {
        switch update {
        case .runStarted:
            [.started]
        case .runCompleted, .runFailed:
            [.completed]
        case .status(let message, _):
            [.status(text(message))]
        case .reasoning(let fragment, _):
            [.reasoning(text(fragment))]
        case .modelOutputPartialUpdated(let reply, _):
            reply.text.map { [.reply($0)] } ?? []
        case .toolRequested(let call, let at):
            [.toolCalled(name: call.name, arguments: call.arguments.jsonString, at: at)]
        case .toolCompleted(let result, let at):
            [
                .toolFinished(
                    name: result.name, output: result.output.textRepresentation,
                    failure: result.failureKind?.rawValue, at: at)
            ]
        case .received, .modelOutputGenerated, .responseRecorded:
            []
        }
    }
}

/// A small value boundary around one Hail agent. A turn is a request and its reply; what the agent
/// does meanwhile comes back with it, as it does it.
public struct HailConversationPeer: Sendable {
    public typealias RunHandler =
        @Sendable (ConversationTurnRequest, _ events: @escaping @Sendable (HailModelEvent) async -> Void) async throws
        -> HailResponse
    public typealias ContextHandler = @Sendable () async throws -> AgentContextSnapshot
    public typealias HistoryHandler = @Sendable () async throws -> AgentHistory
    public typealias DeactivationHandler = @Sendable () async throws -> Void

    private let runHandler: RunHandler
    private let contextHandler: ContextHandler
    private let historyHandler: HistoryHandler
    private let deactivationHandler: DeactivationHandler

    public init(
        run: @escaping RunHandler,
        context: @escaping ContextHandler = {
            throw HailAdapterError.contextUnavailable
        },
        history: @escaping HistoryHandler = { AgentHistory() },
        deactivate: @escaping DeactivationHandler = {}
    ) {
        self.runHandler = run
        self.contextHandler = context
        self.historyHandler = history
        self.deactivationHandler = deactivate
    }

    /// Asks the agent, and waits for its reply: what it does meanwhile reaches `events`, as it does
    /// it.
    public func run(
        to request: ConversationTurnRequest, events: @escaping @Sendable (HailModelEvent) async -> Void
    ) async throws -> HailResponse {
        try await runHandler(request, events)
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
    case emptyResponse
    case contextUnavailable
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
            run: { request, events in
                guard request.conversationID == conversationID else {
                    throw HailAdapterError.conversationMismatch
                }
                let message = request.message
                let input = HailConversationInput(message: message)
                let agent = try await self.agent(for: conversationID)
                // Attachments remain opaque references unless the model fetches one. What the agent
                // does comes back through the turn's own call, the reply so far among it.
                let stream = AgentStream<AgentReply>(actorSystem: actorSystem)
                let following = Task<AgentReply?, Never> {
                    var reply: AgentReply?
                    for await update in stream.updates {
                        if case .responseRecorded(let content, _) = update { reply = content }
                        for event in HailRunMapper.map(update) { await events(event) }
                    }
                    return reply
                }
                do {
                    try await stream.send(input, to: agent)
                } catch {
                    stream.finish()
                    _ = await following.value
                    throw error
                }
                stream.finish()
                guard let reply = await following.value else { throw HailAdapterError.emptyResponse }
                return try HailResponse(reply)
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
            case .emptyResponse:
                return "I couldn’t produce a reply to that message. Please try again."
            case .contextUnavailable:
                return "Context diagnostics are not available for this conversation."
            }
        }
        return HailErrorFormatter.userFacingMessage(error)
    }
}
