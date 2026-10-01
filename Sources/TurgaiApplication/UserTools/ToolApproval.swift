import AnyLanguageModel
import DistributedCluster
import Foundation
import TurgaiDomain

/// Dynamic consent for running a user tool, asked inside the tool's
/// execution. This is deliberately separate from the static authority gate:
/// `Authority.decision` is a synchronous grant over an effect configuration,
/// while approval is an asynchronous question to a human. Authority answers
/// "what may this lane do"; approval answers "does the user consent right
/// now".
public struct ApprovalRequest: Sendable {
    public let toolName: String
    public let arguments: GeneratedContent
    public let command: [String]
    public let workingDirectory: String?
    public let conversationID: String
    public let requesterID: String
    public let turnID: String

    public init(
        toolName: String,
        arguments: GeneratedContent,
        command: [String] = [],
        workingDirectory: String? = nil,
        conversationID: String = "unknown",
        requesterID: String = "unknown",
        turnID: String = "unknown"
    ) {
        self.toolName = toolName
        self.arguments = arguments
        self.command = command
        self.workingDirectory = workingDirectory
        self.conversationID = conversationID
        self.requesterID = requesterID
        self.turnID = turnID
    }

    /// A bounded, human-readable rendering of the arguments for the
    /// approval prompt: one `name: value` line per argument.
    public var summary: String {
        let text = Self.readable(arguments)
        return text.count > 500 ? String(text.prefix(500)) + "…" : text
    }

    private static func readable(_ content: GeneratedContent) -> String {
        switch content.kind {
        case .structure(let properties, let orderedKeys):
            orderedKeys.compactMap { key in
                guard let value = properties[key], value.kind != .null else { return nil }
                return "\(key): \(inline(value))"
            }
            .joined(separator: "\n")
        default:
            inline(content)
        }
    }

    private static func inline(_ content: GeneratedContent) -> String {
        switch content.kind {
        case .string(let text): text
        case .bool(let value): value ? "yes" : "no"
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .array(let elements): elements.map(inline).joined(separator: ", ")
        case .null, .structure: content.jsonString
        }
    }

    public var commandSummary: String {
        let command = command.joined(separator: " ")
        guard !command.isEmpty else { return toolName }
        return command.count > 700 ? String(command.prefix(700)) + "…" : command
    }
}

/// The serializable part of an approval request sent to the channel actor
/// that owns the provider connection.
public struct ChannelApprovalRequest: Codable, Sendable, Equatable {
    public let toolName: String
    public let command: String
    public let workingDirectory: String
    public let arguments: String
    public let conversationID: String
    public let requesterID: String
    public let turnID: String

    public init(_ request: ApprovalRequest) {
        self.toolName = request.toolName
        self.command = request.commandSummary
        self.workingDirectory = request.workingDirectory ?? "(default)"
        self.arguments = request.summary
        self.conversationID = request.conversationID
        self.requesterID = request.requesterID
        self.turnID = request.turnID
    }
}

/// Asks for consent where the request came from: a Telegram chat asks through
/// its channel's inline buttons; any other conversation, such as the web and Mac
/// chat, asks its connected clients.
public struct ChannelToolApproval: ToolApproval {
    private let actorSystem: ClusterSystem
    /// The agent role of the conversation asking, used to find its actor.
    private let agentRole: String

    public init(actorSystem: ClusterSystem, agentRole: String) {
        self.actorSystem = actorSystem
        self.agentRole = agentRole
    }

    public func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        guard let conversationID = ConversationID(stableKey: request.conversationID) else {
            return .denied
        }
        if conversationID.channel.providerName == TelegramProvider.providerID {
            guard let channelID = UUID(uuidString: conversationID.channel.instanceID) else {
                return .denied
            }
            let channel = try await TelegramChannel.resolve(
                on: actorSystem,
                channelID: channelID
            )
            return try await channel.decideApproval(ChannelApprovalRequest(request))
        }
        // The conversation is running the turn that asks, so it's already active.
        let conversation = try await Conversation.resolve(
            on: actorSystem,
            conversationID: conversationID,
            agentDirectoryID: "agent-directory",
            agentRole: agentRole,
            memoryExtraction: nil
        )
        return try await conversation.requestApproval(ChannelApprovalRequest(request))
    }
}

public protocol ToolApproval: Sendable {
    func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision
}

/// Grants every request. The default until a host wires a real consent
/// flow; a tool whose policy is `.always` should not run silently in
/// production, so Turgai's executable installs a Telegram-backed approval.
public struct NoOpApproval: ToolApproval {
    public init() {}

    public func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        .granted
    }
}

/// Safe default for hosts that have not installed a real consent flow.
public struct DenyAllApproval: ToolApproval {
    public init() {}

    public func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        .denied
    }
}
