import DistributedCluster
import Hail
import TurgaiDomain
import TurgaiObjects

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Assembles the tool set for one conversation turn. The agent runtime calls
/// this per turn; the returned tools are everything the model may address
/// directly. Memory is deliberately absent: nothing the model can call writes
/// saved facts — Conversation's background extraction pass is the sole writer.
public enum ConversationTools {
    public static func make(
        context: AgentTurnContext,
        attachmentResolver: AttachmentResolver,
        searchBackend: WebSearchBackend = .duckDuckGo,
        workspaceRoot: String,
        wasmRunnerURL: URL? = nil,
        userTools: UserToolRegistry? = nil,
        approval: any ToolApproval = DenyAllApproval(),
        actorSystem: ClusterSystem? = nil,
        objectCatalog: ObjectCatalog? = nil,
        includeConversationTools: Bool = true
    ) -> [any Tool] {
        guard includeConversationTools else { return [] }
        var tools: [any Tool] = [
            WebSearchTool(backend: searchBackend),
            FetchURLTool(),
            LocationTool(),
            NowTool(),
            FetchAttachmentTool(resolver: attachmentResolver),
        ]
        tools += ScheduleTools(context: context).tools
        tools += WeatherTools().tools
        tools += TimerTools(context: context).tools

        if let actorSystem {
            let owner = ConversationID(stableKey: context.agentID.contextID.rawValue)?.participantUserID
            let session = ObjectSession(
                actorSystem: actorSystem,
                objectCatalog: objectCatalog,
                scopes: owner.map(ObjectScope.visible(to:)) ?? [.shared]
            )
            tools += ObjectTools(session: session).tools
        }

        if let userTools {
            let builtinNames = Set(tools.map(\.name))
            let requesterID = Self.sender(of: context.message)
            let conversationID = context.agentID.contextID.rawValue
            let turnID = context.turnID.rawValue
            for tool in userTools.load() {
                guard !builtinNames.contains(tool.name) else {
                    userTools.reportIssue(
                        .init(
                            source: tool.source,
                            reason: .builtinNameCollision(tool.name)
                        ))
                    continue
                }
                switch tool.body {
                case .process:
                    tools.append(
                        UserProcessTool(
                            tool: tool,
                            workspaceRoot: workspaceRoot,
                            approval: approval,
                            conversationID: conversationID,
                            requesterID: requesterID,
                            turnID: turnID
                        ))
                case .wasm:
                    guard let wasmRunnerURL else {
                        userTools.reportIssue(
                            .init(
                                source: tool.source,
                                reason: .invalidSpec(
                                    "Tool '\(tool.name)': TurgaiWasmRunner is unavailable."
                                )
                            ))
                        continue
                    }
                    tools.append(
                        UserWasmTool(
                            tool: tool,
                            runnerURL: wasmRunnerURL,
                            workspaceRoot: workspaceRoot,
                            approval: approval,
                            conversationID: conversationID,
                            requesterID: requesterID,
                            turnID: turnID
                        ))
                case .prompt:
                    guard let actorSystem else {
                        userTools.reportIssue(
                            .init(
                                source: tool.source,
                                reason: .invalidSpec(
                                    "Tool '\(tool.name)': prompt tools require an actor system."
                                )
                            ))
                        continue
                    }
                    tools.append(
                        UserPromptTool(
                            tool: tool,
                            actorSystem: actorSystem,
                            sourceAgentID: context.agentID,
                            approval: approval,
                            conversationID: conversationID,
                            requesterID: requesterID,
                            turnID: turnID
                        ))
                case .workflow(let workflow):
                    guard !workflow.steps.isEmpty else {
                        userTools.reportIssue(
                            .init(
                                source: tool.source,
                                reason: .invalidSpec(
                                    "Tool '\(tool.name)': workflow must contain at least one step."
                                )
                            ))
                        continue
                    }
                    if workflow.steps.contains(where: { $0.kind == .think }) {
                        guard actorSystem != nil else {
                            userTools.reportIssue(
                                .init(
                                    source: tool.source,
                                    reason: .invalidSpec(
                                        "Tool '\(tool.name)': workflows with think steps require an actor system."
                                    )
                                ))
                            continue
                        }
                    }
                    tools.append(
                        UserWorkflowTool(
                            tool: tool,
                            workspaceRoot: workspaceRoot,
                            actorSystem: actorSystem,
                            sourceAgentID: context.agentID,
                            approval: approval,
                            conversationID: conversationID,
                            requesterID: requesterID,
                            turnID: turnID
                        ))
                }
            }
        }
        return tools
    }

    private static func sender(of message: ChatMessage) -> String {
        switch message {
        case .text(let sender, _, _), .response(let sender, _, _):
            return sender
        default:
            return "unknown"
        }
    }
}
