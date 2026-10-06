import DiscoverableActors
import DistributedCluster
import EventSourcing
import Foundation
import Hail
import TurgaiApplication
import TurgaiHail
import TurgaiPersistence
import VirtualActors

/// One node with the app's agent runtime, giving its agents the app's object tools, as
/// ConversationTools does for every conversation. Nothing outlives it: its journal is in memory,
/// agents keep no snapshots, and its workspace is removed when it stops.
struct EvalNode: Sendable {
    let system: ClusterSystem
    let virtualNode: VirtualNode
    let workspace: URL

    static func start(model: AgentModel) async throws -> EvalNode {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("turgai-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let store = MemoryEventStore()
        let configuration = try Self.configuration(for: model)
        let endpoints = AgentModelEndpointFactory(
            credentials: AgentCredentialStore(files: try FileClient(directory: workspace.appendingPathComponent("credentials"))))
        let runtime = HailRuntimeConfiguration(contextWindow: configuration.contextWindow)
        let plugin = try runtime.makeAgentRuntimePlugin(
            workspaceRoot: workspace.path,
            spawnConfigProvider: { AgentSpawnConfig(agentID: $0, resumesInterruptedTurns: false, snapshotPolicy: .disabled) },
            modelEndpointProvider: { _ in
                try await endpoints.endpoint(
                    model: model, configuration: configuration, temperature: runtime.temperature,
                    ollamaKeepAlive: runtime.ollamaKeepAlive)
            },
            modelSelectionProvider: { _ in ModelConfiguration(model: model) },
            definitionProvider: { config in
                AgentDefinition(role: config.agentID.role, behavior: .init(systemPrompt: "You help the user."))
            },
            turnToolsProvider: { _, actorSystem in
                let session = ObjectSession(actorSystem: actorSystem, scopes: [.shared])
                return TurnTools(
                    tools: ObjectTools(session: session).everyTurn,
                    sources: [ObjectDefiningTools(session: session), ObjectActionTools(session: session)])
            },
            authorityProvider: { _, _ in
                CompositeAuthority()
                    .grantingAll(for: ObjectsGuideEffect.self)
                    .grantingAll(for: ListObjectsEffect.self)
                    .grantingAll(for: DefineObjectEffect.self)
                    .grantingAll(for: RemoveObjectEffect.self)
                    .grantingAll(for: FindObjectsEffect.self)
                    .grantingAll(for: DescribeObjectEffect.self)
                    .grantingAll(for: InvokeObjectEffect.self)
                    .grantingAll(for: ReadObjectEffect.self)
            }
        )
        let system = await ClusterSystem("eval") { settings in
            settings.bindHost = "127.0.0.1"
            settings.bindPort = PortFinder.findAvailablePort(host: "127.0.0.1")
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)
            settings.plugins.install(plugin: ClusterSingletonPlugin())
            let virtualActors = ClusterVirtualActorsPlugin.configuring(&settings)
            settings.plugins.install(plugin: virtualActors)
            settings.plugins.install(plugin: DiscoveryPlugin())
            settings.plugins.install(plugin: ClusterJournalPlugin { _ in store })
            settings.plugins.install(plugin: plugin)
        }
        try await system.cluster.joined(endpoint: system.cluster.endpoint, within: .seconds(10))
        return EvalNode(system: system, virtualNode: await VirtualNode(actorSystem: system), workspace: workspace)
    }

    /// The provider settings the app's profiles use for this model.
    private static func configuration(for model: AgentModel) throws -> AgentProviderConfiguration {
        switch model.provider {
        case .ollama: .ollama(baseURL: URL(string: "http://127.0.0.1:11434")!, contextWindow: 16_384)
        case .system: .appleSystem
        default: throw UnsupportedModel(model: model)
        }
    }

    /// An agent no one has talked to.
    func freshAgent() async throws -> Agent {
        try await system.agent(AgentID(role: Role("eval"), contextID: AgentContextID(UUID().uuidString)))
    }

    func stop() {
        try? system.shutdown()
        try? FileManager.default.removeItem(at: workspace)
    }
}

struct UnsupportedModel: Error, CustomStringConvertible {
    let model: AgentModel
    var description: String { "Only ollama and system models are evaluated, not \(model)." }
}

/// Events kept in memory, so each node starts with no objects and no agent history.
actor MemoryEventStore: EventStore {
    private var events: [String: [Data]] = [:]

    func persistEvent<Event: Codable & Sendable>(_ event: Event, id: String, sequenceNumber: Int64) throws {
        events[id, default: []].append(try JSONEncoder().encode(event))
    }

    func eventStream<Event: Codable & Sendable>(id: String, fromSequenceNumber: Int64) throws -> EventStream<Event> {
        let stored = Array((events[id] ?? []).enumerated().dropFirst(Int(fromSequenceNumber - 1)))
        let envelopes = try stored.map { offset, data in
            EventEnvelope(
                persistenceID: id, sequenceNumber: Int64(offset + 1),
                event: try JSONDecoder().decode(Event.self, from: data))
        }
        return AsyncThrowingStream { continuation in
            envelopes.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}
