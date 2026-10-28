import AnyLanguageModel
import DistributedCluster
import Foundation
import Hail
import Synchronization
import Testing
import TurgaiHail

@testable import TurgaiApplication

/// An agent does one thing at a time, and says so: asked again from within its own turn, which
/// would wait for itself, it's busy answering at once, and the turn answers all the same. Asked
/// after, by whoever it answered, it's idle again.
@Suite(.asAPerson)
struct AgentBusyTests {
    @Test(.timeLimit(.minutes(1)))
    func anAgentAskedWithinItsOwnTurnIsBusy() async throws {
        let agentID = AgentID(role: Role("probe"), contextID: AgentContextID("probe"))
        let system = SystemBox()
        let endpoint = AsksItselfOnce { () async throws -> String in
            guard let actorSystem = system.value else { return "no system" }
            return try await actorSystem.agent(agentID).respond("again")
        }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("turgai-probe-\(UUID())").path
        let agents = try HailRuntimeConfiguration(contextWindow: 16_384).makeAgentRuntimePlugin(
            workspaceRoot: workspace,
            spawnConfigProvider: { AgentSpawnConfig(agentID: $0) },
            modelEndpointProvider: { _ in endpoint },
            modelSelectionProvider: { _ in ModelConfiguration(model: try AgentModel("ollama/test")) },
            authority: { _ in TurgaiAuthority() })
        try await withClusterSystem(
            "probe", store: MemoryEventStore(), hostsVirtualActors: true, installing: { $0.plugins.install(plugin: agents) }
        ) { node in
            system.set(node)
            let agent = try await node.agent(agentID)
            let reply = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await agent.respond("first") }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    return "the first ask never answered"
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            #expect(reply == "answer 1")
            #expect(endpoint.inner == .busy(.responding))
            #expect(try await agent.status == .idle)

            // Asked again by whoever it answered: it's ready.
            let next: String = try await agent.respond("second")
            #expect(next == "answer 2")
            #expect(endpoint.requests == 2)
        }
    }
}

private final class SystemBox: Sendable {
    private let system = Mutex<ClusterSystem?>(nil)
    var value: ClusterSystem? { system.withLock { $0 } }
    func set(_ value: ClusterSystem) { system.withLock { $0 = value } }
}

/// A model that, asked the first time, asks the agent again before it answers, as a tool's object
/// asking it back would; then answers.
private final class AsksItselfOnce: ModelEndpoint, Sendable {
    let model = "test/fake"
    let effectiveContextWindow: Int? = 16_384
    var tokenCounting: TokenCounting { .unavailable }
    private let ask: @Sendable () async throws -> String
    private let asked = Mutex(0)
    private let innerError = Mutex<AgentRuntimeError?>(nil)

    /// Why asking the agent again from within its turn failed, if it did.
    var inner: AgentRuntimeError? { innerError.withLock { $0 } }

    init(ask: @escaping @Sendable () async throws -> String) {
        self.ask = ask
    }

    var requests: Int { asked.withLock { $0 } }

    func stream<Input, Output>(
        request: ModelRequest<Input>,
        tools: [AnyTool],
        authority: any Authority,
        generating: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>>
    where Input: Sendable, Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Sendable {
        let attempt = asked.withLock { count in
            count += 1
            return count
        }
        let ask = self.ask
        return AsyncStream { continuation in
            let task = Task {
                if attempt == 1 {
                    let inner = await Task { () -> AgentRuntimeError? in
                        do {
                            _ = try await ask()
                            return nil
                        } catch let error as AgentRuntimeError {
                            return error
                        } catch {
                            return .infrastructureFailure("\(error)")
                        }
                    }.value
                    innerError.withLock { $0 = inner }
                }
                continuation.yield(.generated(try! Output(GeneratedContent("answer \(attempt)"))))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
