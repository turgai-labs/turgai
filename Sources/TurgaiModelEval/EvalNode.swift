import AnyLanguageModel
import DiscoverableActors
import DistributedCluster
import EventSourcing
import Foundation
import Hail
import RunningActors
import TurgaiAgents
import TurgaiApplication
import TurgaiCalls
import TurgaiDomain
import TurgaiHail
import TurgaiObjects
import TurgaiPersistence
import TurgaiSpaces
import VirtualActors

/// One node with the app's agent runtime, giving its agents the app's object tools, as
/// ConversationTools does for every conversation. Nothing outlives it: its journal is in memory,
/// agents keep no snapshots, and its workspace is removed when it stops.
struct EvalNode: Sendable {
    let system: ClusterSystem
    let virtualNode: VirtualNode
    let workspace: URL
    /// The bot of the asker's space: the model the eval asks, told the eval's instructions.
    let bot: Bot

    static func start(
        model: AgentModel, temperature: Double, instructions: String, objectsPageDescription: String? = nil,
        agents: [EvalAgent] = [], sendsRequests: Bool = false
    ) async throws -> EvalNode {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "turgai-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let store = MemoryEventStore()
        let configuration = try Self.configuration(for: model)
        let endpoints = AgentModelEndpointFactory(
            credentials: AgentCredentialStore(storage: .test),
            transports: ModelTransports(limits: RequestLimitStore.defaultLimits))
        let runtime = HailRuntimeConfiguration(temperature: temperature, contextWindow: configuration.contextWindow)
        let plugin = try runtime.makeAgentRuntimePlugin(
            workspaceRoot: workspace.path,
            spawnConfigProvider: { AgentSpawnConfig(agentID: $0, interruptedTurns: .close, snapshotPolicy: .disabled) },
            modelEndpointProvider: { _, _ in
                let endpoint = try await endpoints.endpoint(
                    model: model, configuration: configuration, temperature: runtime.temperature,
                    ollamaKeepAlive: runtime.ollamaKeepAlive)
                return ProcessInfo.processInfo.environment["TURGAI_EVAL_DUMP"] == "1"
                    ? EvalDumpEndpoint(base: endpoint)
                    : endpoint
            },
            modelSelectionProvider: { _, _ in ModelConfiguration(model: model) },
            definitionProvider: { config, _ in
                // A profile's instructions, as given; blank by default. What the agent can do comes
                // with its tools.
                let own = agents.first { $0.role == config.agentID.role }?.instructions
                return AgentDefinition(role: config.agentID.role, behavior: .init(systemPrompt: own ?? instructions))
            },
            turnToolsProvider: { context, actorSystem in
                // An object's Swift is written by the same model, in a session of its own.
                let writing = try await endpoints.endpoint(
                    model: model, configuration: configuration, temperature: runtime.temperature)
                return try await Self.tools(
                    for: context, on: actorSystem, agents: agents, writing: writing,
                    objectsPageDescription: objectsPageDescription, sendsRequests: sendsRequests)
            },
            // What a turn may do is what its scope allows, as on every node.
            authority: { _ in TurgaiAuthority() }
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
            settings.checkObjectAccess(
                deciding: ObjectCallDecisions(decide: ObjectCallDecisions.default.decide, opening: Space.opens))
            settings.plugins.install(plugin: ClusterJournalPlugin { _ in store })
            settings.plugins.install(plugin: plugin)
            settings.plugins.install(plugin: ToolsAPIPlugin(Self.nodeTools.api))
            // What objects keep running; a task's node lives only as long as the task.
            settings.plugins.install(plugin: RunningActors(recovering: []))
        }
        try await system.cluster.joined(endpoint: system.cluster.endpoint, within: .seconds(10))
        guard let modelName = ModelName(model.id.rawValue) else { throw UnsupportedModel(model: model) }
        return EvalNode(
            system: system, virtualNode: await VirtualNode(actorSystem: system), workspace: workspace,
            bot: Bot(
                name: BotName("Eval")!, instructions: instructions,
                model: BotModel(location: configuration, name: modelName)))
    }

    /// A turn's tools: the objects, made and found, and the task's other agents, which it can ask.
    private static func tools(
        for context: AgentTurnContext, on actorSystem: ClusterSystem, agents: [EvalAgent],
        writing: any ModelEndpoint, objectsPageDescription: String?, sendsRequests: Bool
    ) async throws -> TurnTools {
        // A task's agents, which the others can ask: never itself.
        let others: [Role] = agents.map(\.role).filter { (role: Role) -> Bool in role != context.agentID.role }
        let offered = try await Agent.offered(others, in: Self.space, on: actorSystem)
        // The built-in objects an eval offers, the chats' schedules and timers, each started and
        // checked in there, where the space's code finds it by name.
        let offeredObjects: [DiscoverableObject] = [
            try DiscoverableObject.resolve(
                id: try await Scheduler.of(Self.space, on: actorSystem).id, using: actorSystem),
            try DiscoverableObject.resolve(id: try await Timers.of(Self.space, on: actorSystem).id, using: actorSystem),
        ]
        var builtIns: [ObjectEntry] = []
        for object in offeredObjects {
            await actorSystem.receptionist.checkIn(object, with: .virtualObjects(in: Self.space))
            guard let virtual = object.id.virtualActorID, let description = try? await object.describe() else {
                continue
            }
            builtIns.append(
                ObjectEntry(
                    id: .virtual(virtual), object: object, type: description.type,
                    description: description.description,
                    actions: description.actions.map { ObjectCatalog.signature($0.key, input: $0.value.input) }
                        .sorted(),
                    events: description.events.keys.sorted()))
        }
        let session = try await ObjectSession(
            in: Self.space, actorSystem: actorSystem, agents: offered, builtIns: builtIns)
        let roots: [any HailCore.Tool] = try await ObjectTools(session: session).offered()
        // The node's own tools, for a task that sends requests: as every conversation has them.
        let tools: [any HailCore.Tool] =
            roots + (await session.objectTools()) + (sendsRequests ? Self.nodeTools.turn : [])
        return TurnTools(tools: tools, pages: EvalPages(base: session, introduction: objectsPageDescription))
    }

    /// The tools every node has, under the node's authority.
    private static let nodeTools = NodeTools(authority: { _ in TurgaiAuthority() })

    /// The provider settings the app's profiles use for this model.
    static func configuration(for model: AgentModel) throws -> AgentProviderConfiguration {
        switch model.provider {
        case .ollama:
            .server(ModelServer(software: .ollama, address: .localOllama, key: nil, context: .chosen(.standard)))
        case .system: .local(.appleSystem)
        default: throw UnsupportedModel(model: model)
        }
    }

    /// Who the eval asks as: one person, the admin of a space of their own.
    static let askerID = TurgaiDomain.UserID.account(UUID())
    static let space = SpaceID()

    /// The asker's scope, as their space settles it.
    func asker() async throws -> CallScope {
        let space = try await Space.identified(by: Self.space, on: system)
        if try await space.status() == nil {
            try await space.make(named: SpaceName("Eval")!, admins: NonEmptySet(Self.askerID), bot: bot)
        }
        return try await space.opening(scopeOf: .person(Self.askerID))
    }

    /// An agent no one has talked to.
    func freshAgent() async throws -> Agent {
        try await Agent.identified(
            by: AgentID(role: Role("eval"), contextID: AgentContextID(UUID().uuidString)), on: system)
    }

    func stop() {
        _ = try? system.shutdown()
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
    /// An event as kept: its offset is its place in `journal`, counting from 1.
    private struct Kept {
        let id: String
        let sequenceNumber: Int64
        let tags: Set<EventTag>
        let data: Data
    }

    private var journal: [Kept] = []

    func persistEvent<Event: Codable & Sendable>(
        _ event: Event, id: String, sequenceNumber: Int64, tags: Set<EventTag>
    ) throws {
        journal.append(Kept(id: id, sequenceNumber: sequenceNumber, tags: tags, data: try JSONEncoder().encode(event)))
    }

    func eventStream<Event: Codable & Sendable>(id: String, fromSequenceNumber: Int64) throws -> EventStream<Event> {
        try envelopes { kept, _ in kept.id == id && kept.sequenceNumber >= fromSequenceNumber }
    }

    func currentEventsByTag<Event: Codable & Sendable>(_ tag: EventTag, after offset: Offset) throws
        -> EventStream<Event>
    {
        try envelopes { kept, keptAt in kept.tags.contains(tag) && keptAt > offset }
    }

    /// The events kept so far that `included` takes, each decoded as `Event`.
    private func envelopes<Event: Codable & Sendable>(_ included: (Kept, Offset) -> Bool) throws -> EventStream<Event> {
        let envelopes = try journal.enumerated().compactMap { index, kept -> EventEnvelope<Event>? in
            let offset = Offset(Int64(index + 1))
            guard included(kept, offset) else { return nil }
            return EventEnvelope(
                persistenceID: kept.id, sequenceNumber: kept.sequenceNumber, offset: offset,
                event: try JSONDecoder().decode(Event.self, from: kept.data))
        }
        return AsyncThrowingStream { continuation in
            for envelope in envelopes { continuation.yield(envelope) }
            continuation.finish()
        }
    }
}
