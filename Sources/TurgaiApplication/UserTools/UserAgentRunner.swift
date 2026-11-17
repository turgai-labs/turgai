import AnyLanguageModel
import DistributedCluster
import Hail
import HailCore
import TurgaiConversations
import TurgaiDomain
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Shared host-side implementation for user-tool `think` stages. The script
/// workflow never receives the actor or its capability; it only receives the
/// resulting text value.
enum UserAgentRunner {
    static func run(
        instruction: String,
        toolName: String,
        actorSystem: ClusterSystem,
        sourceAgentID: AgentID
    ) async throws -> String {
        let childID = AgentID(
            role: .toolRun,
            contextID: AgentContext.toolRun(
                toolName, calledBy: sourceAgentID.role, in: try AgentContext.space(of: sourceAgentID), run: UUID()
            ).contextID
        )
        let agent: Agent = try await actorSystem.agent(childID)
        return try await Agent.answering(as: childID) { try await agent.respond(instruction) }
    }
}
