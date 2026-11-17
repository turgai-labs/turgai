import DistributedCluster
import Hail
import TurgaiCalls
import VirtualActors

extension Agent {
    /// Runs `body`, a turn of the agent with `id`, with the agent entered into the chain it's
    /// asked in: what its turn calls comes from it, and the agent is left as the turn ends.
    public static func answering<Value: Sendable>(
        as id: AgentID, _ body: () async throws -> Value
    ) async throws -> Value {
        let agent = CallActor.virtual(VirtualActorID(rawValue: id.rawValue))
        return try await CallChain.$current.withValue(try CallChain.entering(agent)) { try await body() }
    }
}
