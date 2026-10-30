import ArgumentParser
import DiscoverableActors
import DistributedCluster
import DurableWorkflows
import EventSourcing
import Hail
import Logging
import PostgresEventStore
import PostgresNIO
import SQLiteEventStore
import SQLiteNIO
import ServiceLifecycle
import TurgaiApplication
import TurgaiDomain
import TurgaiHail
import TurgaiMemory
import TurgaiObjects
import TurgaiPersistence
import TurgaiTelegram
import TurgaiWeb
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

actor TurgaiRuntimeSnapshotSource {
    private var provider: (@Sendable (Membership) async -> [TurgaiAgentRuntimeSnapshot])?

    func setProvider(
        _ provider: @escaping @Sendable (Membership) async -> [TurgaiAgentRuntimeSnapshot]
    ) {
        self.provider = provider
    }

    /// What each running agent is doing, as whoever asks on behalf of `scope` may see it.
    func snapshots(as viewer: Membership) async -> [TurgaiAgentRuntimeSnapshot] {
        guard let provider else { return [] }
        return await provider(viewer)
    }
}

private enum RuntimeAgentKind {
    case userTool
    case profile
}

private enum TurgaiModelSelectionError: Error, Sendable {
    case missingProfile(String)
    case disabledProfile(String)
}

struct TurgaiAppService: Service, Sendable {
    private let environment: [String: String]
    private let workspaceRoot: String
    private let turgaiDirectory: URL
    /// Turgai's database, which the journal is kept in unless it's kept in PostgreSQL.
    private let persistence: TurgaiPersistence
    private let agentProfiles: TurgaiAgentProfileStore
    private let agentCredentials: AgentCredentialStore
    private let requestLimits: RequestLimitStore
    private let channelSecrets: ChannelSecretStore
    private let conversations: ConversationStorage
    private let channels: ChannelStorage
    private let runtimeSnapshotSource: TurgaiRuntimeSnapshotSource
    private let objectCatalogSource: TurgaiObjectCatalogSource
    private let webChatBridge: TurgaiWebChatBridge
    private let websitePort: WebsitePort
    /// What the node's log shows.
    private let logLevel: Logger.Level

    init(
        environment: [String: String],
        workspaceRoot: String,
        turgaiDirectory: URL,
        persistence: TurgaiPersistence,
        agentProfiles: TurgaiAgentProfileStore,
        agentCredentials: AgentCredentialStore,
        requestLimits: RequestLimitStore,
        channelSecrets: ChannelSecretStore,
        conversations: ConversationStorage,
        channels: ChannelStorage,
        runtimeSnapshotSource: TurgaiRuntimeSnapshotSource,
        objectCatalogSource: TurgaiObjectCatalogSource,
        webChatBridge: TurgaiWebChatBridge,
        websitePort: WebsitePort,
        logLevel: Logger.Level
    ) {
        self.environment = environment
        self.workspaceRoot = workspaceRoot
        self.turgaiDirectory = turgaiDirectory
        self.persistence = persistence
        self.agentProfiles = agentProfiles
        self.agentCredentials = agentCredentials
        self.requestLimits = requestLimits
        self.channelSecrets = channelSecrets
        self.conversations = conversations
        self.channels = channels
        self.runtimeSnapshotSource = runtimeSnapshotSource
        self.objectCatalogSource = objectCatalogSource
        self.webChatBridge = webChatBridge
        self.websitePort = websitePort
        self.logLevel = logLevel
    }

    func run() async throws {
        let configuration = try TurgaiWebConfiguration.load(directory: turgaiDirectory)
        guard configuration.isReady else {
            throw ValidationError("Turgai onboarding is incomplete.")
        }

        guard try await agentProfiles.defaultProfile() != nil else {
            throw ValidationError("At least one agent must be configured.")
        }
        // A profile's endpoint carries its own context window, read with the profile on each turn.
        let runtimeConfiguration = HailRuntimeConfiguration()
        let endpointFactory = AgentModelEndpointFactory(
            credentials: agentCredentials, transports: requestLimits.transports)
        let modelEndpointProvider: ModelEndpointProvider = { request in
            guard let model = try? AgentModel(request.model),
                let profile = try await Self.profile(of: request.agentID, in: agentProfiles), profile.model == model
            else { return nil }
            return try await endpointFactory.endpoint(
                for: profile,
                temperature: runtimeConfiguration.temperature,
                ollamaKeepAlive: runtimeConfiguration.ollamaKeepAlive,
                reasoning: request.reasoning
            )
        }
        guard let storageConfiguration = configuration.storage else {
            throw ValidationError("Storage configuration is missing.")
        }
        let journal = try JournalStorage(
            configuration: storageConfiguration,
            postgresPassword: configuration.postgresPassword
        )

        try await withThrowingTaskGroup(of: Void.self) { persistenceTasks in
            // Each store is built exactly once, here at the composition root:
            // the same instance serves boot recovery and the journal plugin.
            let stores: Stores
            switch journal {
            case .local:
                stores = try await Self.stores(on: persistence.connection)
            case .postgres(let client):
                // A PostgreSQL query naturally waits until PostgresClient.run
                // is active. The client task remains structured around the
                // whole app phase and is cancelled when the app exits.
                persistenceTasks.addTask {
                    await client.run()
                }
                stores = try await Self.stores(on: client)
            }
            let eventStore = stores.events
            let snapshotStore = stores.snapshots
            let userToolsDirectory =
                turgaiDirectory
                .appendingPathComponent("tools", isDirectory: true)
            let wasmRunnerURL = WasmRunnerLocator.executableURL(environment: environment)
            let telegramFiles = TelegramFiles()
            // The tools every node has: a turn's, and those object code calls, decided as every
            // effect is, by the scope of the call.
            let nodeTools = NodeTools(
                searchBackend: try Self.makeSearchBackend(environment: environment),
                authority: { _ in TurgaiAuthority() })
            let userToolRegistry = Self.userToolRegistry(in: userToolsDirectory)
            let turnTools = TurnToolSources(
                agentProfiles: agentProfiles, endpointFactory: endpointFactory,
                runtimeConfiguration: runtimeConfiguration,
                telegramFiles: telegramFiles, nodeTools: nodeTools, workspaceRoot: workspaceRoot,
                wasmRunnerURL: wasmRunnerURL, userToolRegistry: userToolRegistry)
            let runtimePlugin = try runtimeConfiguration.makeAgentRuntimePlugin(
                workspaceRoot: workspaceRoot,
                // An agent is activated by identity alone, so its configuration
                // is a policy over that identity. Both kinds of agent keep the
                // default workspace, private to the agent id: per conversation
                // for profile agents (a group chat's members share one by
                // construction), fresh per spawn for helpers, whose id embeds
                // a UUID.
                spawnConfigProvider: { agentID in Self.spawnConfig(for: agentID) },
                modelEndpointProvider: modelEndpointProvider,
                modelSelectionProvider: { request in try await Self.modelSelection(for: request, in: agentProfiles) },
                definitionProvider: { spawnConfig in try await Self.definition(for: spawnConfig, in: agentProfiles) },
                turnToolsProvider: { context, actorSystem in
                    try await turnTools.tools(for: context, on: actorSystem)
                },
                // No agent has an authority of its own: what a turn may do is what its scope allows.
                authority: { _ in TurgaiAuthority() }
            )
            // The plugin is the stores' long-term owner: it receives the
            // instances built above and hosts them for every journaled actor.
            let journalPlugin = ClusterJournalPlugin(
                factory: { _ in eventStore },
                snapshotFactory: { _ in snapshotStore }
            )
            let workflowsPlugin = DurableWorkflowsPlugin()
            let channelRuntimePlugin = TurgaiChannelRuntimePlugin(
                agentProfiles: agentProfiles,
                secrets: channelSecrets,
                telegramFiles: telegramFiles,
                endpoints: endpointFactory,
                conversations: conversations
            )

            // Nodes find each other through the cluster daemon, as in swift-chat.
            let system = await ClusterSystem("turgai") { settings in
                settings.bindHost = "127.0.0.1"
                // The lowest address leads the cluster, compared as a string, and cluster
                // singletons such as Hail's active-agent index run on the leader. This port
                // sorts before the daemon's (3137) and the objects node's ephemeral one, so
                // the only node hosting those singletons leads.
                settings.bindPort = 2550
                settings.discovery = .clusterd
                settings.logging.logLevel = logLevel
                settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)
                settings.plugins.install(plugin: ClusterSingletonPlugin())
                let virtualActorsPlugin = ClusterVirtualActorsPlugin.configuring(&settings)
                settings.plugins.install(plugin: virtualActorsPlugin)
                settings.plugins.install(plugin: DiscoveryPlugin())
                settings.propagateCallChain()
                settings.checkObjectAccess()
                settings.plugins.install(plugin: journalPlugin)
                settings.plugins.install(plugin: runtimePlugin)
                settings.plugins.install(plugin: workflowsPlugin)
                settings.plugins.install(plugin: channelRuntimePlugin)
                settings.plugins.install(plugin: ToolsAPIPlugin(nodeTools.api))
            }

            try await system.cluster.joined(endpoint: system.cluster.endpoint, within: .seconds(10))
            // The shared production dependency facade for tool effects. The
            // generic parameter is only a carrier; the stored virtual-actor
            // actions serve every effect type.
            ActorSystemDependency<ChatSayEffect>.prepare(
                .live(
                    on: system,
                    models: ChatModels(
                        agentProfiles: agentProfiles, endpoints: endpointFactory,
                        temperature: runtimeConfiguration.temperature,
                        ollamaKeepAlive: runtimeConfiguration.ollamaKeepAlive)))
            let virtualNode = await VirtualNode(actorSystem: system)
            let scheduleWorker = await DurableActivityDispatchWorker<ScheduleWorkflow>(
                actorSystem: system,
                activities: ScheduleActivities(agentProfiles: agentProfiles)
            )
            let scheduleTimerWorker = await DurableActivityDispatchWorker<TimerWorkflow>(
                actorSystem: system,
                activities: TimerActivities(agentProfiles: agentProfiles)
            )
            let objectScheduleWorker = await DurableActivityDispatchWorker<ObjectScheduleWorkflow>(
                actorSystem: system,
                activities: ObjectScheduleActivities()
            )
            let objectTimerWorker = await DurableActivityDispatchWorker<ObjectTimerWorkflow>(
                actorSystem: system,
                activities: ObjectScheduleActivities()
            )
            let channelRuntime = try await system.turgaiChannelRuntime.dependencies()
            let connections = channelRuntime.connections
            await objectCatalogSource.set(channelRuntime.objectCatalog)
            let runtimeSnapshotProvider: @Sendable (Membership) async -> [TurgaiAgentRuntimeSnapshot] = {
                await Self.runtimeSnapshots(on: system, as: $0)
            }
            await runtimeSnapshotSource.setProvider(runtimeSnapshotProvider)
            let clusterService = TurgaiClusterService(
                system: system,
                virtualNode: virtualNode,
                scheduleWorker: scheduleWorker,
                scheduleTimerWorker: scheduleTimerWorker,
                objectScheduleWorker: objectScheduleWorker,
                objectTimerWorker: objectTimerWorker
            )

            let logger = system.log
            let websitePort = websitePort
            let webChatBridge = webChatBridge
            // Each part starts on its own: none waits for another, so a slow or failing one holds
            // up nothing else, and messages are taken from the start.
            let parts = [
                // The node's built-in objects, reached by the ids they always have.
                Startup("built-in objects", logger: logger) {
                    try await Weather.start(on: system)
                    try await Website.start(on: system, port: websitePort)
                    try await Scheduler.start(on: system)
                    try await Timers.start(on: system)
                },
                // The objects models made: started again after a restart, each on behalf of
                // whoever made it, so what they follow and run keeps going.
                Startup("made objects", logger: logger) {
                    try await DynamicObjects.resolve(on: system).start()
                },
                Startup("workflows", logger: logger) {
                    try await system.workflows.recoverAll(ofType: ScheduleWorkflow.self)
                    try await system.workflows.recoverAll(ofType: TimerWorkflow.self)
                    try await system.workflows.recoverAll(ofType: ObjectScheduleWorkflow.self)
                    try await system.workflows.recoverAll(ofType: ObjectTimerWorkflow.self)
                },
                Startup("web chat", logger: logger) {
                    await webChatBridge.install(
                        connections,
                        objectCatalog: channelRuntime.objectCatalog,
                        conversations: conversations,
                        channels: channels,
                        actorSystem: system
                    )
                },
            ]
            // Every channel's bot, run by the node while its channel is enabled.
            let telegram = TelegramService(
                actorSystem: system, dependencies: channelRuntime, channels: channels)

            logger.info("Turgai is ready")
            logger.info("Workspace: \(workspaceRoot)")
            let serviceGroup = ServiceGroup(
                configuration: ServiceGroupConfiguration(
                    services: [.init(service: clusterService), .init(service: connections), .init(service: telegram)]
                        + parts.map { .init(service: $0, successTerminationBehavior: .ignore) },
                    logger: logger
                )
            )
            try await serviceGroup.run()
            persistenceTasks.cancelAll()
        }
    }

    private static func makeSearchBackend(environment: [String: String]) throws -> WebSearchBackend {
        let raw = environment["TURGAI_SEARCH"]?
            .trimmed()
            .lowercased()
        switch raw {
        case nil, "", "duckduckgo":
            return .duckDuckGo
        case "searxng":
            guard let urlString = environment["TURGAI_SEARXNG_URL"],
                let url = URL(string: urlString),
                url.scheme == "http" || url.scheme == "https"
            else {
                throw ValidationError(
                    "TURGAI_SEARCH=searxng requires TURGAI_SEARXNG_URL to be an http(s) URL."
                )
            }
            return .searxng(baseURL: url)
        case "ollama":
            guard let key = environment["OLLAMA_API_KEY"], !key.isEmpty else {
                throw ValidationError("TURGAI_SEARCH=ollama requires OLLAMA_API_KEY.")
            }
            return .ollama(baseURL: URL(string: "https://ollama.com")!, apiKey: key)
        case let other?:
            throw ValidationError(
                "Unknown TURGAI_SEARCH backend \(other); expected duckduckgo, searxng, or ollama."
            )
        }
    }
}

/// One part of starting the node, done once and on its own: it waits for no other part, and no
/// other waits for it. Whether it started, it says in the log; one still starting when the node
/// shuts down stops there.
struct Startup: Service {
    let part: String
    let logger: Logger
    let step: @Sendable () async throws -> Void

    init(_ part: String, logger: Logger, step: @escaping @Sendable () async throws -> Void) {
        self.part = part
        self.logger = logger
        self.step = step
    }

    func run() async {
        logger.info("Starting \(part)")
        do {
            try await cancelWhenGracefulShutdown { try await step() }
            logger.info("Started \(part)")
        } catch {
            logger.error("Couldn't start \(part)", metadata: ["error": .string(String(describing: error))])
        }
    }
}

struct TurgaiClusterService: Service {
    let system: ClusterSystem
    let virtualNode: VirtualNode
    let scheduleWorker: DurableActivityDispatchWorker<ScheduleWorkflow>
    let scheduleTimerWorker: DurableActivityDispatchWorker<TimerWorkflow>
    let objectScheduleWorker: DurableActivityDispatchWorker<ObjectScheduleWorkflow>
    let objectTimerWorker: DurableActivityDispatchWorker<ObjectTimerWorkflow>

    func run() async throws {
        let (shutdownRequests, shutdownContinuation) = AsyncStream<Void>.makeStream()
        defer {
            shutdownContinuation.finish()
        }

        try await withGracefulShutdownHandler {
            try await withThrowingTaskGroup(of: Bool.self) {
                group in
                group.addTask {
                    try await system.terminated
                    return false
                }
                group.addTask {
                    for await _ in shutdownRequests {
                        return true
                    }
                    return false
                }
                do {
                    let gracefulShutdownRequested = try await group.next() ?? false
                    if gracefulShutdownRequested || Task.isCancelled {
                        try system.shutdown()
                    }
                } catch {
                    _ = try? system.shutdown()
                    throw error
                }
                // ClusterSystem.terminated does not respond to task
                // cancellation. Initiate shutdown before leaving the
                // group, which must wait for that child to finish.
                group.cancelAll()
            }
        } onGracefulShutdown: {
            shutdownContinuation.yield(())
        }
    }
}

// MARK: How agents are built

extension TurgaiAppService {
    /// The profile an agent runs as: its own, or the default one for a helper.
    static func profile(of agentID: AgentID, in agentProfiles: TurgaiAgentProfileStore) async throws
        -> TurgaiAgentProfile?
    {
        let role = agentID.role.rawValue
        return role == "user-tool" ? try await agentProfiles.defaultProfile() : try await agentProfiles.profile(id: role)
    }

    /// The user's tools in `directory`, each problem with one logged.
    static func userToolRegistry(in directory: URL) -> UserToolRegistry {
        let logger = Logger(label: "turgai.usertools")
        return UserToolRegistry(directory: directory) { (issue: UserToolLoadIssue) in
            logger.warning(
                "User tool issue",
                metadata: [
                    "source": .string(issue.source.lastPathComponent),
                    "reason": .string(String(describing: issue.reason)),
                ]
            )
        }
    }

    /// An agent's durable configuration, from its identity: a helper's is fresh each time, a
    /// profile agent's is recovered by its conversation.
    static func spawnConfig(for agentID: AgentID) -> AgentSpawnConfig {
        switch agentID.role.rawValue {
        case "user-tool":
            AgentSpawnConfig(agentID: agentID, interruptedTurns: .close, snapshotPolicy: .disabled)
        default:
            // Profile agents: their Conversation owns recovery and
            // starts exactly one model run after its own journal
            // replays; Hail resuming too would be a second driver.
            AgentSpawnConfig(agentID: agentID, interruptedTurns: .close)
        }
    }

    /// The model an agent's turn runs on: its profile's, or the default profile's for a helper.
    static func modelSelection(
        for request: ModelSelectionRequest, in agentProfiles: TurgaiAgentProfileStore
    ) async throws -> ModelConfiguration {
        let role = request.agentID.role.rawValue
        if role == "user-tool" {
            guard let currentDefault = try await agentProfiles.defaultProfile() else {
                throw TurgaiModelSelectionError.missingProfile(
                    TurgaiAgentProfileStore.defaultProfileID
                )
            }
            return ModelConfiguration(
                model: currentDefault.model,
                reasoningEffort: currentDefault.reasoningEffort
            )
        }
        guard let profile = try await agentProfiles.profile(id: role) else {
            throw TurgaiModelSelectionError.missingProfile(role)
        }
        guard profile.availability == .enabled else {
            throw TurgaiModelSelectionError.disabledProfile(role)
        }
        return ModelConfiguration(
            model: profile.model,
            reasoningEffort: profile.reasoningEffort
        )
    }

    /// What an agent is: its profile's instructions and persona, or a helper's fixed task.
    static func definition(
        for spawnConfig: AgentSpawnConfig, in agentProfiles: TurgaiAgentProfileStore
    ) async throws -> AgentDefinition? {
        let role = spawnConfig.agentID.role.rawValue
        let agentKind: RuntimeAgentKind = role == "user-tool" ? .userTool : .profile
        let profile: TurgaiAgentProfile?
        switch agentKind {
        case .userTool: profile = try await agentProfiles.defaultProfile()
        case .profile: profile = try await agentProfiles.profile(id: role)
        }
        guard let profile else {
            throw TurgaiModelSelectionError.missingProfile(role)
        }
        switch (agentKind, profile.availability) {
        case (.profile, .disabled):
            throw TurgaiModelSelectionError.disabledProfile(role)
        case (.profile, .enabled), (.userTool, _): break
        }
        let customInstructions =
            profile.instructions.trimmed()
        let personaInstructions =
            profile.persona?.trimmed() ?? ""
        let systemPrompt: String
        switch agentKind {
        case .userTool:
            systemPrompt =
                "You are an isolated helper agent. Follow the supplied task, return only the useful result, and do not perform side effects."
        case .profile:
            // The profile's own instructions, blank unless its owner writes some. What the
            // agent can do comes with its tools and pages, not from here.
            systemPrompt = customInstructions
        }
        let execution: AgentExecutionPolicy
        switch agentKind {
        case .userTool:
            execution = AgentExecutionPolicy(
                sandbox: .readOnly,
                approvalPolicy: .onRequest
            )
        case .profile:
            execution = .autonomousWorkspace
        }
        return AgentDefinition(
            role: spawnConfig.agentID.role,
            behavior: .init(
                systemPrompt: systemPrompt,
                execution: execution
            ),
            persona: {
                switch agentKind {
                case .userTool: return nil
                case .profile:
                    guard !personaInstructions.isEmpty else { return nil }
                    return AgentPersona(
                        displayName: profile.name,
                        instructions: personaInstructions
                    )
                }
            }()
        )
    }

    /// What the object writer was asked and wrote, logged.
    @Sendable static func log(_ event: WriterEvent) {
        let logger = Logger(label: "turgai.objectwriter")
        // How big what it's asked is, and which objects it's shown: the
        // prompt itself follows, in full.
        if case .asked(let prompt) = event {
            let objects: [Substring] = prompt.split(separator: "\n").filter { (line: Substring) -> Bool in
                line.hasPrefix("- ") && line.contains(": ") && !line.hasPrefix("- The ")
            }
            let names: [String] = objects.map { (line: Substring) -> String in
                String(line.dropFirst(2).prefix { $0 != ":" })
            }
            logger.info(
                "Object writer asked",
                metadata: ["characters": "\(prompt.count)", "objects": "\(names.joined(separator: ", "))"])
        }
        logger.info("\(event.written)")
    }

    /// What each running profile agent is doing, for the dashboard, asked on behalf of `viewer`, as
    /// the dashboard's group settles their scope: none when it can't.
    static func runtimeSnapshots(on system: ClusterSystem, as viewer: Membership) async -> [TurgaiAgentRuntimeSnapshot]
    {
        guard let group = try? await Group.resolve(on: system, id: .dashboard),
            (try? await group.setRole(viewer.role, of: viewer.person)) != nil,
            // Viewing does nothing: it spends nothing that's allowed once.
            let scope = try? await group.scope(of: viewer.person)
        else { return [] }
        let entries = (try? await system.agentRuntime.allAgents()) ?? []
        return await CallChain.$current.withValue(.start(scope, in: nil)) { await snapshots(of: entries, on: system) }
    }

    private static func snapshots(of entries: [AgentDirectoryEntry], on system: ClusterSystem) async
        -> [TurgaiAgentRuntimeSnapshot]
    {
        await withTaskGroup(
            of: TurgaiAgentRuntimeSnapshot?.self, returning: [TurgaiAgentRuntimeSnapshot].self
        ) { group in
            for entry in entries where entry.role.rawValue != "user-tool" {
                group.addTask {
                    guard
                        let agent: Agent = try? await system.agent(entry.agentID),
                        let snapshot = try? await agent.contextSnapshot
                    else {
                        return nil
                    }
                    return TurgaiAgentRuntimeSnapshot(
                        profileID: entry.role.rawValue,
                        contextID: snapshot.agentID.contextID.rawValue,
                        phase: snapshot.state,
                        currentTool: nil,
                        contextUsedTokens: snapshot.contextUsage?.usedTokens,
                        contextLimitTokens: snapshot.contextUsage?.limitTokens,
                        historyTurnCount: snapshot.historyTurnCount,
                        totalTokens: snapshot.usageSummary.totalTokens
                    )
                }
            }

            var snapshots: [TurgaiAgentRuntimeSnapshot] = []
            for await snapshot in group {
                if let snapshot { snapshots.append(snapshot) }
            }
            return snapshots.sorted {
                ($0.profileID, $0.contextID) < ($1.profileID, $1.contextID)
            }
        }
    }
}

// MARK: Where the journal is kept

extension TurgaiAppService {
    /// The journal's stores, and how to find the conversations and channels it holds.
    struct Stores: Sendable {
        let events: any EventStore
        let snapshots: any SnapshotStore
    }

    /// The journal in one SQLite file, its tables set up.
    static func stores(on connection: SQLiteConnection) async throws -> Stores {
        let events = SQLiteEventStore(connection: connection)
        let snapshots = SQLiteSnapshotStore(connection: connection)
        try await events.setupDatabase()
        try await snapshots.setupDatabase()
        return Stores(events: events, snapshots: snapshots)
    }

    /// The journal in PostgreSQL, its tables set up.
    static func stores(on client: PostgresClient) async throws -> Stores {
        let events = PostgresEventStore(client: client)
        let snapshots = PostgresSnapshotStore(client: client)
        try await events.setupDatabase()
        try await snapshots.setupDatabase()
        return Stores(events: events, snapshots: snapshots)
    }
}

/// What a turn's tools are built from: each turn gets them anew, for the agent taking it.
struct TurnToolSources: Sendable {
    let agentProfiles: TurgaiAgentProfileStore
    let endpointFactory: AgentModelEndpointFactory
    let runtimeConfiguration: HailRuntimeConfiguration
    let telegramFiles: TelegramFiles
    let nodeTools: NodeTools
    let workspaceRoot: String
    let wasmRunnerURL: URL?
    let userToolRegistry: UserToolRegistry

    func tools(for context: AgentTurnContext, on actorSystem: ClusterSystem) async throws -> TurnTools {
        let objectCatalog = try await actorSystem.turgaiChannelRuntime.dependencies().objectCatalog
        // An object's Swift is written by the agent's own model, in a session of its own.
        let writer: ObjectWriter? =
            if let profile = try await agentProfiles.profile(id: context.agentID.role.rawValue) {
                ObjectWriter(
                    endpoint: try await endpointFactory.endpoint(
                        for: profile,
                        temperature: runtimeConfiguration.temperature,
                        ollamaKeepAlive: runtimeConfiguration.ollamaKeepAlive
                    ),
                    report: TurgaiAppService.log(_:))
            } else {
                nil
            }
        var tools = try await ConversationTools.make(
            context: context,
            telegramFiles: telegramFiles,
            nodeTools: nodeTools,
            workspaceRoot: workspaceRoot,
            wasmRunnerURL: wasmRunnerURL,
            userTools: userToolRegistry,
            actorSystem: actorSystem,
            objectCatalog: objectCatalog,
            writer: writer,
            // Every enabled profile's agent can be asked, as an object.
            agents: try await agentProfiles.profiles().filter { $0.availability == .enabled }.map {
                Role($0.id)
            },
            includeConversationTools: context.agentID.role.rawValue != "user-tool"
        )
        // Hail's files and agent messaging, for the agents granted them.
        if context.agentID.role.rawValue != "user-tool" {
            tools.tools =
                try await actorSystem.agentRuntime.agentTools(for: context, actorSystem: actorSystem)
                + tools.tools
        }
        return tools
    }
}
