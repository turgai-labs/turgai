import AnyLanguageModel

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
    /// approval prompt.
    public var summary: String {
        let json = arguments.jsonString
        return json.count > 500 ? String(json.prefix(500)) + "…" : json
    }

    public var commandSummary: String {
        let command = command.joined(separator: " ")
        guard !command.isEmpty else { return toolName }
        return command.count > 700 ? String(command.prefix(700)) + "…" : command
    }
}

public enum ApprovalDecision: Sendable, Equatable {
    case granted
    case denied
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
