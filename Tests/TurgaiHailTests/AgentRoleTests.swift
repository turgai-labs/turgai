import Hail
import Testing
import TurgaiDomain

@testable import TurgaiApplication
@testable import TurgaiHail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// An agent's id crosses the cluster as Hail writes it, `<role>-<context>`, and is read back up to
/// its first hyphen: a bot's agent, and a user's tool thinking, are still what they were.
struct AgentRoleTests {
    private func acrossTheWire(_ agent: AgentID) throws -> AgentID {
        try JSONDecoder().decode(AgentID.self, from: JSONEncoder().encode(agent))
    }

    @Test func aBotsAgentIsStillItsBotsAfterCrossing() throws {
        let bot = BotID()
        let agent = AgentID(
            role: Role(bot.role), contextID: AgentContextID("\(UUID().uuidString)/turgai:\(UUID().uuidString)"))
        let crossed = try acrossTheWire(agent)
        #expect(crossed == agent)
        #expect(BotID(role: crossed.role.rawValue) == bot)
        // A bot's id as written isn't its agents' role.
        #expect(BotID(role: bot.description) == nil)
        #expect(BotID(bot.description) == bot)
    }

    @Test func aToolRunIsStillOneAfterCrossing() throws {
        let agent = AgentID(
            role: .toolRun,
            contextID: AgentContext.toolRun(
                "summarize", calledBy: Role(BotID().role), in: SpaceID(), run: UUID()
            ).contextID)
        let crossed = try acrossTheWire(agent)
        #expect(crossed.role == .toolRun)
        #expect(AgentContext(crossed.contextID) == AgentContext(agent.contextID))
    }
}
