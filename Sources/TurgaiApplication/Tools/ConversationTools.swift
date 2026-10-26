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
        writer: ObjectWriter? = nil,
        agents: [Role] = [],
        includeConversationTools: Bool = true
    ) async throws -> TurnTools {
        guard includeConversationTools else { return TurnTools() }
        let working = AgentContext(context.agentID.contextID)
        var tools: [any Tool] = [
            WebSearchTool(backend: searchBackend),
            FetchURLTool(),
            LocationTool(),
            NowTool(),
            FetchAttachmentTool(resolver: attachmentResolver),
        ]
        // Schedules and timers reply in a conversation: an agent asked as an object has none.
        if case .conversation? = working {
            tools += ScheduleTools(context: context).tools
            tools += TimerTools(context: context).tools
        }
        // Tools that belong together and say what they're for are a page: the turn starts from
        // their link, and the page says the rest.
        let groups: [ToolGroup] = [WeatherTools().group]

        var pages: any ToolPages = NoToolPages()
        // The person the agent works for.
        let owner = working?.person
        if let actorSystem {
            // The other agents, which it can ask: never itself.
            let askable = try await Agent.offered(agents.filter { $0 != context.agentID.role }, on: actorSystem)
            let session = ObjectSession(
                actorSystem: actorSystem,
                objectCatalog: objectCatalog,
                scopes: owner.map(ObjectScope.visible(to:)) ?? [.shared],
                agents: askable,
                writer: writer,
                request: context.input.text
            )
            // What objects can be: found, listed, made, changed and removed, at the root; and the
            // objects themselves, each a tool to read it.
            tools += try await ObjectTools(session: session).tools().filter { $0.name != "use_object" }
            tools += await session.objectTools()
            pages = session
            if let owner { tools.append(RecallTool(actorSystem: actorSystem, person: owner)) }
        }

        if let userTools {
            tools += Self.userTools(
                from: userTools, besides: Set(tools.map(\.name)), context: context, person: owner,
                workspaceRoot: workspaceRoot, wasmRunnerURL: wasmRunnerURL, approval: approval, actorSystem: actorSystem)
        }
        return TurnTools(tools: tools, groups: groups, pages: pages)
    }

    /// The user's tools a turn may use: each one built for this turn, those named like a built-in
    /// one or that can't run here reported instead.
    private static func userTools(
        from userTools: UserToolRegistry, besides builtinNames: Set<String>, context: AgentTurnContext,
        person owner: TurgaiDomain.UserID?, workspaceRoot: String, wasmRunnerURL: URL?, approval: any ToolApproval,
        actorSystem: ClusterSystem?
    ) -> [any Tool] {
        var tools: [any Tool] = []
        // Asked on behalf of the person whose conversation this is.
        let requesterID = owner?.rawValue ?? ""
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
        return tools
    }
}
