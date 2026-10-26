import AnyLanguageModel
import DistributedCluster
import Hail
import HailCore
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A user-authored prompt tool. It runs an isolated Hail agent with the
/// rendered instruction and returns that agent's typed String response to the
/// parent model as ordinary tool output.
public struct UserPromptTool: HailCore.Tool {
    public typealias Input = GeneratedContent
    public typealias Effect = CoordinationEffect

    public let tool: UserTool
    public let actorSystem: ClusterSystem
    public let sourceAgentID: AgentID
    public let approval: any ToolApproval
    public let conversationID: String
    public let requesterID: String
    public let turnID: String

    public init(
        tool: UserTool,
        actorSystem: ClusterSystem,
        sourceAgentID: AgentID,
        approval: any ToolApproval,
        conversationID: String = "unknown",
        requesterID: String = "unknown",
        turnID: String = "unknown"
    ) {
        self.tool = tool
        self.actorSystem = actorSystem
        self.sourceAgentID = sourceAgentID
        self.approval = approval
        self.conversationID = conversationID
        self.requesterID = requesterID
        self.turnID = turnID
    }

    public var name: String { tool.name }
    public var description: String { tool.description }
    public var schema: ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: tool.arguments)
    }

    public func effect(for input: GeneratedContent) throws -> CoordinationEffect {
        _ = try tool.renderPrompt(input)
        guard case .prompt(let prompt) = tool.body else {
            throw ToolError.invalidArgument("body", value: "not a prompt")
        }
        guard prompt.agentRole == nil || prompt.agentRole == "user-tool" else {
            throw ToolError.invalidArgument(
                "agentRole",
                value: prompt.agentRole ?? ""
            )
        }
        return CoordinationEffect(
            subsystem: "user-tool",
            action: "prompt:\(name)"
        )
    }

    public func run(
        _ input: GeneratedContent, in scope: borrowing ToolScope<Never>,
        token: borrowing EffectToken<CoordinationEffect>
    ) async throws -> CallReturn {
        _ = token
        if tool.approval == .always {
            let decision = try await approval.decide(
                ApprovalRequest(
                    toolName: name,
                    arguments: input,
                    conversationID: conversationID,
                    requesterID: requesterID,
                    turnID: turnID
                )
            )
            guard decision == .granted else {
                return .text("The user declined to run \(name).")
            }
        }

        let instruction = try tool.renderPrompt(input)
        let childID = AgentID(
            role: Role("user-tool"),
            contextID: AgentContextID(
                "\(sourceAgentID.contextID.rawValue)-\(name)-\(UUID().uuidString)"
            )
        )
        let agent: Agent = try await actorSystem.agent(childID)
        let response: String = try await Agent.answering(as: childID) { try await agent.respond(instruction) }
        return .text(response)
    }
}
