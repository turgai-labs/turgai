import DistributedCluster
import Hail
import TurgaiApplication
import TurgaiCalls
import TurgaiDomain
import TurgaiHail
import TurgaiSpaces

extension TurgaiRouteDependencies {
    /// What each running agent of `space`'s bots is doing, asked on behalf of `viewer`, as the space
    /// settles their scope: none when they're not in it.
    func runtimeSnapshots(of space: TurgaiDomain.SpaceID, for viewer: TurgaiDomain.UserID) async
        -> [TurgaiAgentRuntimeSnapshot]
    {
        // Viewing does nothing: it spends nothing that's allowed once.
        guard let scope = try? await Space.identified(by: space, on: system).scope(of: viewer) else { return [] }
        let entries = ((try? await system.agentRuntime.allAgents()) ?? []).filter {
            AgentContext($0.agentID.contextID)?.space == space
        }
        let system = system
        return await CallChain.$current.withValue(.start(scope, in: nil)) {
            await withTaskGroup(of: TurgaiAgentRuntimeSnapshot?.self) { group in
                for entry in entries {
                    // A bot's agents only, each as its bot: not a user's tool thinking.
                    guard let bot = BotID(role: entry.role.rawValue) else { continue }
                    group.addTask {
                        guard let agent: Agent = try? await Agent.identified(by: entry.agentID, on: system),
                            let snapshot = try? await agent.contextSnapshot
                        else { return nil }
                        return TurgaiAgentRuntimeSnapshot(
                            profileID: bot.description,
                            contextID: snapshot.agentID.contextID.rawValue,
                            phase: snapshot.state,
                            currentTool: nil,
                            contextUsedTokens: snapshot.contextUsage?.usedTokens,
                            contextLimitTokens: snapshot.contextUsage?.limitTokens ?? nil,
                            historyTurnCount: snapshot.historyTurnCount,
                            totalTokens: snapshot.usageSummary.totalTokens
                        )
                    }
                }
                var snapshots: [TurgaiAgentRuntimeSnapshot] = []
                for await snapshot in group {
                    if let snapshot { snapshots.append(snapshot) }
                }
                return snapshots.sorted { ($0.profileID, $0.contextID) < ($1.profileID, $1.contextID) }
            }
        }
    }
}
