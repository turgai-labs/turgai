import AnyLanguageModel
import DiscoverableActors
import DistributedCluster
import EventSourcing
import Foundation
import Hail
import TurgaiApplication
import TurgaiDomain
import TurgaiHail
import TurgaiObjects
import TurgaiPersistence
import VirtualActors

/// One node with the app's agent runtime, giving its agents the app's object tools, as
/// ConversationTools does for every conversation. Nothing outlives it: its journal is in memory,
/// agents keep no snapshots, and its workspace is removed when it stops.
struct EvalNode: Sendable {
    let system: ClusterSystem
    let virtualNode: VirtualNode
    let workspace: URL
    let objectCatalog: ObjectCatalog

    static func start(
        model: AgentModel, temperature: Double, instructions: String, objectsPageDescription: String? = nil,
        agents: [EvalAgent] = []
    ) async throws -> EvalNode {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "turgai-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let store = MemoryEventStore()
        // One catalog for the node, following the objects from when it starts, as the app keeps
        // one: a session making its own would start empty, and a later turn wouldn't find what an
        // earlier one made.
        let catalog = Catalog()
        let configuration = try Self.configuration(for: model)
        let endpoints = AgentModelEndpointFactory(
            credentials: AgentCredentialStore(
                files: try FileClient(directory: workspace.appendingPathComponent("credentials"))),
            transports: ModelTransports(limits: RequestLimitStore.defaultLimits))
        let runtime = HailRuntimeConfiguration(temperature: temperature, contextWindow: configuration.contextWindow)
        let plugin = try runtime.makeAgentRuntimePlugin(
            workspaceRoot: workspace.path,
            spawnConfigProvider: { AgentSpawnConfig(agentID: $0, interruptedTurns: .close, snapshotPolicy: .disabled) },
            modelEndpointProvider: { _ in
                let endpoint = try await endpoints.endpoint(
                    model: model, configuration: configuration, temperature: runtime.temperature,
                    ollamaKeepAlive: runtime.ollamaKeepAlive)
                return ProcessInfo.processInfo.environment["TURGAI_EVAL_DUMP"] == "1"
                    ? EvalDumpEndpoint(base: endpoint)
                    : endpoint
            },
            modelSelectionProvider: { _ in ModelConfiguration(model: model) },
            definitionProvider: { config in
                // A profile's instructions, as given; blank by default. What the agent can do comes
                // with its tools.
                let own = agents.first { $0.role == config.agentID.role }?.instructions
                return AgentDefinition(role: config.agentID.role, behavior: .init(systemPrompt: own ?? instructions))
            },
            turnToolsProvider: { context, actorSystem in
                // An object's Swift is written by the same model, in a session of its own.
                let writing = try await endpoints.endpoint(
                    model: model, configuration: configuration, temperature: runtime.temperature)
                // A task's agents, which the others can ask: never itself.
                let offered = try await Agent.offered(
                    agents.map(\.role).filter { $0 != context.agentID.role }, on: actorSystem)
                let session = ObjectSession(
                    actorSystem: actorSystem, objectCatalog: await catalog.current, scopes: [.shared],
                    agents: offered, caller: Party(agent: context.agentID),
                    writer: ObjectWriter(
                        endpoint: writing, report: { FileHandle.standardError.write(Data($0.written.utf8)) }),
                    request: context.input.text)
                let tools =
                    try await ObjectTools(session: session).tools().filter { $0.name != "use_object" }
                    + session.objectTools()
                return TurnTools(tools: tools, pages: EvalPages(base: session, introduction: objectsPageDescription))
            },
            authorityProvider: { _, _ in
                CompositeAuthority()
                    .grantingAll(for: FindObjectsEffect.self)
                    .grantingAll(for: ListObjectsEffect.self)
                    .grantingAll(for: MakeObjectEffect.self)
                    .grantingAll(for: ToolPageEffect.self)
                    .grantingAll(for: EditObjectEffect.self)
                    .grantingAll(for: UseObjectEffect.self)
                    .grantingAll(for: RemoveObjectEffect.self)
                    .grantingAll(for: InvokeObjectEffect.self)
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
            settings.propagateCallChain()
            settings.plugins.install(plugin: ClusterJournalPlugin { _ in store })
            settings.plugins.install(plugin: plugin)
        }
        try await system.cluster.joined(endpoint: system.cluster.endpoint, within: .seconds(10))
        await catalog.start(on: system)
        guard let objectCatalog = await catalog.current else { throw EvalCatalogUnavailable() }
        return EvalNode(
            system: system, virtualNode: await VirtualNode(actorSystem: system), workspace: workspace,
            objectCatalog: objectCatalog)
    }

    /// The provider settings the app's profiles use for this model.
    static func configuration(for model: AgentModel) throws -> AgentProviderConfiguration {
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

/// Writes the exact Hail transcript and callable tool schemas sent to the provider, for evals
/// where we need to inspect what the model saw. Set `TURGAI_EVAL_DUMP=1` to enable it.
private struct EvalDumpEndpoint: ModelEndpoint {
    let base: any ModelEndpoint

    var model: String { base.model }
    var effectiveContextWindow: Int? { base.effectiveContextWindow }
    var tokenCounting: TokenCounting { base.tokenCounting }

    func stream<Input, Output>(
        request: ModelRequest<Input>,
        tools: [AnyTool],
        authority: any Authority,
        generating: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>>
    where Input: Sendable, Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Sendable {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let entries =
            (try? encoder.encode(request.entries)).flatMap { String(data: $0, encoding: .utf8) } ?? "<unavailable>"
        let schemas =
            (try? encoder.encode(tools.map(\.schema))).flatMap { String(data: $0, encoding: .utf8) } ?? "<unavailable>"
        FileHandle.standardError.write(
            Data(
                "\n=== EVAL REQUEST: TRANSCRIPT ===\n\(entries)\n=== EVAL REQUEST: TOOLS ===\n\(schemas)\n=== END EVAL REQUEST ===\n"
                    .utf8))
        // What the model generates, as it streams: its activity and tool calls as they come, and
        // what it had generated when it ended or failed, in full.
        let events = base.stream(
            request: request, tools: tools, authority: authority, generating: generating, purpose: purpose)
        return AsyncStream { continuation in
            let task = Task {
                var last = ""
                func write(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }
                for await event in events {
                    switch event {
                    case .activity(let activity): write("=== EVAL ACTIVITY: \(activity)\n")
                    case .toolCall(let call): write("=== EVAL TOOL CALL: \(call)\n")
                    case .partialUpdated(let partial): last = String(describing: partial)
                    case .generated(let output):
                        write("=== EVAL GENERATED ===\n\(output)\n=== END EVAL GENERATED ===\n")
                    case .failed(let error):
                        write("=== EVAL FAILED: \(error)\n=== LAST PARTIAL ===\n\(last)\n=== END LAST PARTIAL ===\n")
                    case .usage, .contextUsage: break
                    }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct EvalCatalogUnavailable: Error {}

/// The node's object catalog, made once the node is running.
private actor Catalog {
    private(set) var current: ObjectCatalog?

    func start(on system: ClusterSystem) async {
        current = await ObjectCatalog(actorSystem: system)
    }
}

/// A profile's agent in a task: its role, and its own instructions.
struct EvalAgent: Sendable {
    let role: Role
    let instructions: String
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
            for envelope in envelopes { continuation.yield(envelope) }
            continuation.finish()
        }
    }
}
