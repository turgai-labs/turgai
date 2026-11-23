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
    /// The agent's turn that made it.
    public let agentTurn: AgentTurnID

    public var content: String {
        reply.text
    }

    /// The agent's reply, from its turn `agentTurn`, which says something: an empty one is an error.
    public init(_ reply: AgentReply, of agentTurn: AgentTurnID) throws(HailAdapterError) {
        guard let reply = ConversationReply(reply.text) else {
            throw .emptyResponse
        }
        self.reply = reply
        self.agentTurn = agentTurn
    }

    public init(reply: ConversationReply, agentTurn: AgentTurnID) {
        self.reply = reply
        self.agentTurn = agentTurn
    }
}

extension AgentTurnID {
    /// The agent's turn `turn`, as Turgai keeps it.
    public init(_ turn: Hail.TurnID) {
        self.init(rawValue: turn.rawValue)
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
    /// The agent opened its turn `agentTurn` for the call.
    case started(AgentTurnID)
    case status(String)
    /// The reply so far, whole: it replaces what was shown before.
    case reply(String)
    case reasoning(String)
    /// A tool the model called, with its arguments as the model wrote them.
    case toolCalled(name: String, arguments: String, at: Date)
    /// A tool call's result; `failure` says why it failed, when it did.
    case toolFinished(name: String, output: String, failure: String?, at: Date)
    /// A call refused exactly this, which the turn's scope didn't allow.
    case needed(ExactRequest)
    case completed
}

public enum HailRunMapper {
    private static func text(_ content: GeneratedContent) -> String {
        if case .string(let value) = content.kind {
            return value
        }
        return content.jsonString
    }

    /// Why a tool call failed, in a word.
    public static func failure(_ kind: ToolFailureKind) -> String {
        switch kind {
        case .invalidArguments: "invalidArguments"
        case .rejected: "rejected"
        case .unavailable: "unavailable"
        case .failed: "failed"
        }
    }

    /// The exact request a call's refusal refused, which its scope didn't allow.
    private static func needed(by result: ToolResult) -> [HailModelEvent] {
        guard case .rejected(let refusal)? = result.failureKind, let request = ExactRequest(encoded: refusal.refused)
        else { return [] }
        return [.needed(request)]
    }

    /// What the agent did in a turn, as the turn's call brought it back.
    public static func map(_ update: AgentRunUpdate<AgentReply>) -> [HailModelEvent] {
        switch update.event {
        case .runStarted:
            [.started(AgentTurnID(update.turn))]
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
                    failure: result.failureKind.map(failure), at: at)
            ] + needed(by: result)
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
    public typealias DeactivationHandler = @Sendable () async throws -> Void

    private let runHandler: RunHandler
    private let contextHandler: ContextHandler
    private let deactivationHandler: DeactivationHandler

    public init(
        run: @escaping RunHandler,
        context: @escaping ContextHandler = {
            throw HailAdapterError.contextUnavailable
        },
        deactivate: @escaping DeactivationHandler = {}
    ) {
        self.runHandler = run
        self.contextHandler = context
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

/// Resolves one durable Hail agent per Turgai conversation, for each bot that answers in it: its
/// identity is the bot's role in that conversation of its space.
public struct HailAgentAdapter: Sendable {
    public let actorSystem: ClusterSystem
    public let agentRole: String
    /// The space the conversation is one of, as the conversation was given it.
    public let space: SpaceID

    public init(actorSystem: ClusterSystem, agentRole: String, space: SpaceID) {
        self.actorSystem = actorSystem
        self.agentRole = agentRole
        self.space = space
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
                // Attachments stay ids, got when the model asks for one. What the agent does comes
                // back through the turn's own call, the reply so far among it.
                let stream = AgentStream<AgentReply>(actorSystem: actorSystem)
                let following = Task<(AgentReply, AgentTurnID)?, Never> {
                    var reply: (AgentReply, AgentTurnID)?
                    for await update in stream.updates {
                        if case .responseRecorded(let content, _) = update.event {
                            reply = (content, AgentTurnID(update.turn))
                        }
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
                guard let (reply, agentTurn) = await following.value else { throw HailAdapterError.emptyResponse }
                return try HailResponse(reply, of: agentTurn)
            },
            context: {
                try await self.agent(for: conversationID).contextSnapshot
            },
            deactivate: {
                try await self.deactivate(for: conversationID)
            }
        )
    }

    private func agent(for conversationID: ConversationID) async throws -> Agent {
        try await Agent.identified(by: Self.agentID(for: conversationID, in: space, role: agentRole), on: actorSystem)
    }

    public func deactivate(for conversationID: ConversationID) async throws {
        let agent = try await agent(for: conversationID)
        guard try await actorSystem.virtualActors.deactivate(agent) else { return }
    }

    /// The agent answering as `role` in the conversation `conversationID` of `space`.
    public static func agentID(for conversationID: ConversationID, in space: SpaceID, role: String) -> AgentID {
        AgentID(role: Role(role), contextID: contextID(for: conversationID, in: space))
    }

    /// The context of the agents answering in the conversation `conversationID` of `space`.
    public static func contextID(for conversationID: ConversationID, in space: SpaceID) -> AgentContextID {
        AgentContextID("\(space.rawValue.uuidString)/\(conversationID.stableKey)")
    }

    /// The conversation `agentID` answers in, and its space: none for an agent that answers in none.
    public static func conversation(of agentID: AgentID) -> (space: SpaceID, conversation: ConversationID)? {
        conversation(in: agentID.contextID)
    }

    /// The conversation an agent of `context` answers in, and its space: none for a context that's
    /// no conversation's.
    public static func conversation(in context: AgentContextID) -> (space: SpaceID, conversation: ConversationID)? {
        let context = context.rawValue
        guard let slash = context.firstIndex(of: "/"), let space = UUID(uuidString: String(context[..<slash])),
            let conversation = ConversationID(stableKey: String(context[context.index(after: slash)...]))
        else { return nil }
        return (SpaceID(rawValue: space), conversation)
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
