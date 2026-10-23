import AnyLanguageModel
import DistributedCluster
import Hail
import HailCore
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
        sourceAgentID: AgentID,
        turnID: String
    ) async throws -> String {
        let childID = AgentID(
            role: Role("user-tool"),
            contextID: AgentContextID(
                "\(sourceAgentID.contextID.rawValue)-\(toolName)-\(UUID().uuidString)"
            )
        )
        let agent: Agent = try await actorSystem.agent(childID)
        return try await agent.respond(
            instruction,
            inputID: "\(turnID):\(toolName)"
        )
    }
}
