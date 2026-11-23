import DiscoverableActors
import DistributedCluster
import Foundation
import Hail
import Testing
import TurgaiDomain
import TurgaiHail
import TurgaiObjects

@testable import TurgaiApplication
@testable import TurgaiSpaces

/// The space the agents are asked in.
private let askedIn = AsAPerson.person.space

@Suite(.asAPerson)
struct AskedAgentTests {
    /// The agents asked as objects are shared, as made objects are: each by its own id, listed apart
    /// on the objects page, with its tools, and found by name from code. One not offered, such as the
    /// asking agent's own, isn't listed. None starts to be listed: only the one code reaches.
    @Test(.timeLimit(.minutes(1)))
    func agentsAreListedAndFoundByTheirIds() async throws {
        let started = StartedAgents()
        try await withAgentNodes(started) { objects, sessionNode in
            _ = try await Agent.offered([Role("conversation")], in: askedIn, on: objects)
            let offered = try await Agent.offered([Role("planner"), Role("chef")], in: askedIn, on: sessionNode)
            let session = ObjectSession(
                in: AsAPerson.person.space,
                objects: try await DynamicObjects.of(AsAPerson.person.space, on: sessionNode), actorSystem: sessionNode,
                agents: offered)

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
                    - id: `chef`; type: `Agent` — An agent: ask it something, and it answers. Takes respond(request: String).
                    - id: `planner`; type: `Agent` — An agent: ask it something, and it answers. Takes respond(request: String).
                    """), "\(page)")
            #expect(!page.contains("`conversation`"))

            let planner = try await session.id(written: "planner")
            #expect(await session.actionTools(of: planner).map(\.name) == ["planner_respond"])
            #expect(await started.roles.isEmpty)

            // Code in a shared object finds one by its name; two of one type never collide.
            let found = try #require(
                try await ObjectNames.object(named: "chef", in: AsAPerson.person.space, using: sessionNode))
            #expect(
                found.object.id.virtualActorID.map { ObjectID.virtual($0) }
                    == Agent.objectID(of: Agent.asked(Role("chef"), in: askedIn)))
            #expect(await started.roles == ["chef"])
        }
    }
}

extension AskedAgentTests {
    /// An agent offered from two nodes is one object: each node checks in its own reference to it,
    /// and code on either finds it by its name through that node's.
    @Test(.timeLimit(.minutes(1)))
    func anAgentOfferedFromTwoNodesIsOneObject() async throws {
        try await withAgentNodes(StartedAgents()) { objects, sessionNode in
            _ = try await Agent.offered([Role("planner")], in: askedIn, on: objects)
            _ = try await Agent.offered([Role("planner")], in: askedIn, on: sessionNode)
            for node in [objects, sessionNode] {
                for _ in 0..<50
                where await node.receptionist.lookup(.virtualObjects(in: AsAPerson.person.space)).count < 2 {
                    try await Task.sleep(for: .milliseconds(100))
                }
                #expect(await node.receptionist.lookup(.virtualObjects(in: AsAPerson.person.space)).count == 2)

                let found = try #require(
                    try await ObjectNames.object(named: "planner", in: AsAPerson.person.space, using: node))
                #expect(
                    found.object.id.virtualActorID.map { ObjectID.virtual($0) }
                        == Agent.objectID(of: Agent.asked(Role("planner"), in: askedIn)))
                #expect(found.object.id.node == node.cluster.node)
            }
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
        modelSelectionProvider: { _, _ in ModelConfiguration(model: try AgentModel("ollama/test")) },
        authority: { _ in TurgaiAuthority() })
    try await withClusterSystem(
        "objects", store: store, hostsVirtualActors: true, installing: { $0.plugins.install(plugin: agents) }
    ) { objects in
        try await withClusterSystem("session", store: store, joining: objects, hostsVirtualActors: false) { session in
            try await body(objects, session)
        }
    }
}
