import DiscoverableActors
import DistributedCluster
import Foundation
import Hail
import Testing
import TurgaiDomain
import TurgaiHail
import TurgaiObjects

@testable import TurgaiApplication

@Suite
struct AskedAgentTests {
    /// The agents asked on a person's behalf are objects in their scope: each by its own id, listed
    /// apart on the objects page, with its tools, and found by name from code. One not offered, such
    /// as the asking agent's own, isn't listed. None starts to be listed: only the one code reaches.
    @Test(.timeLimit(.minutes(1)))
    func agentsAreListedAndFoundByTheirIds() async throws {
        let started = StartedAgents()
        try await withAgentNodes(started) { objects, sessionNode in
            let ann = TurgaiDomain.UserID(rawValue: "participant:test:ann")
            _ = try await Agent.offered([Role("conversation")], to: ann, on: objects)
            let offered = try await Agent.offered([Role("planner"), Role("chef")], to: ann, on: sessionNode)
            let session = ObjectSession(actorSystem: sessionNode, scopes: ObjectScope.visible(to: ann), agents: offered)

            var page = ""
            for _ in 0..<50 {
                page = try await session.objectsPage().output.textRepresentation
                if page.contains("`chef`") && page.contains("`planner`") { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(
                page.contains(
                    """
                    Agents:
                    - id: `chef`; type: `Agent` — An agent: ask it something, and it answers. Takes ask(request: String).
                    - id: `planner`; type: `Agent` — An agent: ask it something, and it answers. Takes ask(request: String).
                    """), "\(page)")
            #expect(!page.contains("`conversation`"))

            let planner = try await session.id(written: "planner")
            #expect(await session.actionTools(of: planner).map(\.name) == ["planner_ask"])
            #expect(await started.roles.isEmpty)

            // Code finds one by its name; two of one type never collide.
            let found = try #require(
                try await ObjectNames.object(named: "chef", in: ObjectScope.visible(to: ann), using: sessionNode))
            #expect(found.object.id.virtualActorID.map { ObjectID.virtual($0) } == Agent.objectID(Role("chef"), askedBy: ann))
            #expect(try await ObjectNames.object(named: "planner", in: [.shared], using: sessionNode) == nil)
            #expect(await started.roles == ["chef"])
        }
    }
}

/// The agents started, by role.
private actor StartedAgents {
    private(set) var roles: [String] = []
    func start(_ agent: AgentID) { roles.append(agent.role.rawValue) }
}

/// Object nodes, the first also running Hail's agents, which start where they're asked for.
private func withAgentNodes(
    _ started: StartedAgents,
    _ body: (_ objects: ClusterSystem, _ session: ClusterSystem) async throws -> Void
) async throws {
    let store = MemoryEventStore()
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("turgai-agents-\(UUID())").path
    let agents = try HailRuntimeConfiguration(contextWindow: 16_384).makeAgentRuntimePlugin(
        workspaceRoot: workspace,
        spawnConfigProvider: { agentID in
            await started.start(agentID)
            return AgentSpawnConfig(agentID: agentID)
        },
        modelSelectionProvider: { _ in ModelConfiguration(model: try AgentModel("ollama/test")) })
    try await withClusterSystem(
        "objects", store: store, hostsVirtualActors: true, installing: { $0.plugins.install(plugin: agents) }
    ) { objects in
        try await withClusterSystem("session", store: store, joining: objects, hostsVirtualActors: false) { session in
            try await body(objects, session)
        }
    }
}
