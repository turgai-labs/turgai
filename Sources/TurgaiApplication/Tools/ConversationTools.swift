import DistributedCluster
import Hail
import TurgaiCalls
import TurgaiDomain
import TurgaiHail
import TurgaiObjects
import TurgaiPeople
import TurgaiSpaces

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
        nodeTools: NodeTools,
        workspaceRoot: String,
        wasmRunnerURL: URL? = nil,
        userTools: UserToolRegistry? = nil,
        actorSystem: ClusterSystem? = nil,
        agents: [Role] = [],
        linking: PersonLinking? = nil,
        includeConversationTools: Bool = true
    ) async throws -> TurnTools {
        guard includeConversationTools else { return TurnTools() }
        let working = AgentContext(context.agentID.contextID)
        // The node's tools, which object code calls too.
        var tools: [any Tool] =
            nodeTools.turn + [
                LocationTool(),
                NowTool(),
            ]
        // A chat's attachments, got through the connection the chat is on, while that serves it.
        if case .conversation(let conversation, let space)? = working, let actorSystem,
            let connection = UUID(uuidString: conversation.channel.instanceID).map(ConnectionID.init(rawValue:)),
            let run = try? await ConnectionRun.of(connection, in: space, on: actorSystem),
            (try? await run.servesAttachments) == true
        {
            tools += Telegram(fetch: { try await run.attachment($0) }).tools
        }
        var pages: any ToolPages = NoToolPages()
        // The person the agent works for: in a conversation, whoever its turn answers. One asked
        // as an object works for no one person.
        let owner: TurgaiDomain.UserID? =
            if case .conversation = working { CallChain.current?.scope.person } else { nil }
        // Objects are its space's, and the built-in ones, as its space hands them to whoever the turn is
        // for: an agent in no space, or a turn on no one's behalf, reaches none.
        if let actorSystem, let space = working?.space, let person = CallChain.current?.scope.person {
            // The other agents, which it can ask: never itself.
            let askable = try await Agent.offered(
                agents.filter { $0 != context.agentID.role }, in: space, on: actorSystem)
            let session = try await ObjectSession(
                in: space,
                actorSystem: actorSystem,
                agents: askable,
                // What code makes by name in the space: a page, as it says it is.
                madeByName: [Page.describe()]
            )
            // What objects can be: found, listed, made, changed and removed, at the root; and the
            // objects themselves, each a tool to read it.
            tools += try await ObjectTools(session: session).offered()
            tools += await session.objectTools()
            pages = session
            // What's remembered about whoever it answers, as each of their linked persons does too,
            // when there's anything to recall.
            if let owner {
                let persons = [owner] + (try await linking?.linked(to: owner) ?? [])
                var recallable = false
                for person in persons where !recallable {
                    recallable = try await User.identified(by: person, on: actorSystem).recallable()
                }
                if recallable { tools.append(RecallTool(actorSystem: actorSystem, persons: persons)) }
            }
        }

        if let userTools {
            tools += Self.userTools(
                from: userTools, besides: Set(tools.map(\.name)), context: context, workspaceRoot: workspaceRoot,
                wasmRunnerURL: wasmRunnerURL, actorSystem: actorSystem)
        }
        return TurnTools(tools: tools, pages: pages)
    }

    /// The user's tools a turn may use: each one built for this turn, those named like a built-in
    /// one or that can't run here reported instead.
    private static func userTools(
        from userTools: UserToolRegistry, besides builtinNames: Set<String>, context: AgentTurnContext,
        workspaceRoot: String, wasmRunnerURL: URL?, actorSystem: ClusterSystem?
    ) -> [any Tool] {
        var tools: [any Tool] = []
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
                        workspaceRoot: workspaceRoot
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
                        workspaceRoot: workspaceRoot
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
                        sourceAgentID: context.agentID
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
                        sourceAgentID: context.agentID
                    ))
            }
        }
        return tools
    }
}
