import AnyLanguageModel
import DiscoverableActors
import DistributedCluster
import Foundation
import Hail
import Synchronization
import Testing
import TurgaiDomain
import TurgaiHail
import TurgaiObjects

@testable import TurgaiApplication
@testable import TurgaiSpaces

/// An agent asked by a call that came from its own answer, through objects and nodes, is told it's
/// itself: the call chain says so, wherever the call went.

/// The space the agents are asked in.
private let askedIn = AsAPerson.person.space

@Suite(.asAPerson)
struct AskedByItselfTests {
    static let relay = """
        actor Relay {
            func plan(request: String) async throws -> String {
                try await Agent(id: "planner").respond(request: request)
            }
        }
        """

    @Test(.timeLimit(.minutes(1)))
    func anAgentAskedFromItsOwnAnswerIsToldItIsItself() async throws {
        let turn = PlannerTurn()
        let store = MemoryEventStore()
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("turgai-itself-\(UUID())").path
        let agents = try HailRuntimeConfiguration(contextWindow: 16_384).makeAgentRuntimePlugin(
            workspaceRoot: workspace,
            spawnConfigProvider: { AgentSpawnConfig(agentID: $0) },
            modelEndpointProvider: { _, _ in turn },
            modelSelectionProvider: { _, _ in ModelConfiguration(model: try AgentModel("ollama/test")) },
            authority: { _ in TurgaiAuthority() })
        let installing: @Sendable (inout ClusterSystemSettings) -> Void = { $0.plugins.install(plugin: agents) }
        try await withClusterSystem("objects", store: store, hostsVirtualActors: true, installing: installing) {
            objects in
            try await withClusterSystem("session", store: store, joining: objects, hostsVirtualActors: false) {
                sessionNode in
                // Each node offers the agents, as each node's sessions do.
                _ = try await Agent.offered([Role("planner")], in: askedIn, on: objects)
                let offered = try await Agent.offered([Role("planner")], in: askedIn, on: sessionNode)
                let writing = ObjectSession(
                    in: AsAPerson.person.space,
                    objects: try await DynamicObjects.of(AsAPerson.person.space, on: sessionNode),
                    actorSystem: sessionNode, agents: offered)
                let script = try Script(
                    code: Self.relay, type: "Relay", uses: await writing.others(except: "Relay").uses)
                _ = try await DynamicObjects.of(AsAPerson.person.space, on: sessionNode).create(
                    name: "Relay", spec: .new(script))

                // The planner's turn calls objects as its tools do, from the other node.
                turn.uses(
                    ObjectSession(
                        in: AsAPerson.person.space,
                        objects: try await DynamicObjects.of(AsAPerson.person.space, on: sessionNode),
                        actorSystem: sessionNode, agents: offered))
                let asking = ObjectSession(
                    in: AsAPerson.person.space,
                    objects: try await DynamicObjects.of(AsAPerson.person.space, on: sessionNode),
                    actorSystem: sessionNode, agents: offered)
                let answer = try await asking.invoke(
                    try await asking.id(written: "planner"), action: "respond", arguments: #"{"request": "plan"}"#)

                #expect(answer == "answer")
                #expect(
                    turn.relayed?.contains("The planner agent is you: this call came from your own answer.") == true,
                    "\(turn.relayed ?? "nothing")")
            }
        }
    }
}

/// The planner's model: asked, it plans through the relay, which asks the planner, then answers.
private final class PlannerTurn: ModelEndpoint, Sendable {
    let model = "test/fake"
    let effectiveContextWindow: Int? = 16_384
    var tokenCounting: TokenCounting { .unavailable }
    private let session = Mutex<ObjectSession?>(nil)
    private let result = Mutex<String?>(nil)

    /// What planning through the relay came to.
    var relayed: String? { result.withLock { $0 } }

    func uses(_ session: ObjectSession) { self.session.withLock { $0 = session } }

    func stream<Input, Output>(
        request: ModelRequest<Input>,
        tools: [AnyTool],
        authority: any Authority,
        generating: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>>
    where Input: Sendable, Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Sendable {
        let session = self.session.withLock { $0 }
        return AsyncStream { continuation in
            let task = Task {
                if let session {
                    let relayed: String
                    do {
                        let relay = try await session.id(written: "relay")
                        let reply = try await session.invoke(relay, action: "plan", arguments: #"{"request": "plan"}"#)
                        relayed = "\(reply)"
                    } catch {
                        relayed = String(describing: error)
                    }
                    self.result.withLock { $0 = relayed }
                }
                continuation.yield(.generated(try! Output(GeneratedContent("answer"))))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
