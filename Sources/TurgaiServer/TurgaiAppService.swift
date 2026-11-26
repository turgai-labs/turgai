import ArgumentParser
import DiscoverableActors
import DistributedCluster
import DurableWorkflows
import EventSourcing
import Hail
import Hummingbird
import HummingbirdWebSocket
import Logging
import PostgresEventStore
import PostgresNIO
import RunningActors
import SQLiteEventStore
import SQLiteNIO
import ServiceLifecycle
import TurgaiAgents
import TurgaiApplication
import TurgaiCalls
import TurgaiConversations
import TurgaiDomain
import TurgaiHail
import TurgaiMemory
import TurgaiObjects
import TurgaiPeople
import TurgaiPersistence
import TurgaiSpaces
import TurgaiTelegram
import TurgaiWeb
import VirtualActors
import TurgaiTimers

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Why an agent has no bot to run as.
private enum AgentBotError: Error, Sendable, CustomStringConvertible {
    /// Its role is no bot's.
    case notABot(Role)
    /// It answers for nothing in a space.
    case inNoSpace(AgentID)
    /// Its space no longer has the bot.
    case noSuchBot(BotID, in: SpaceID)

    var description: String {
        switch self {
        case .notABot(let role): "the agent \(role.rawValue) is no bot"
        case .inNoSpace(let agentID): "the agent \(agentID.rawValue) answers in no space"
        case .noSuchBot(let bot, let space): "the space \(space.rawValue) has no bot \(bot.rawValue)"
        }
    }
}

struct TurgaiAppService: Service, Sendable {
    private let environment: [String: String]
    private let workspaceRoot: String
    private let turgaiDirectory: URL
    /// Turgai's database, which the journal is kept in unless it's kept in PostgreSQL.
    private let persistence: TurgaiPersistence
    private let agentCredentials: AgentCredentialStore
    private let requestLimits: RequestLimitStore
    private let channelSecrets: ChannelSecretStore
    /// Who's the same human as whom.
    private let linking: PersonLinking
    /// The accounts.
    private let auth: TurgaiAuth
    /// Where the space directory is kept: the spaces each person is in.
    private let spaceDirectory: SpaceDirectoryStorage
    /// Where the conversation directory is kept: the conversations each person is in.
    private let conversationDirectory: ConversationDirectoryStorage
    /// How far the memory notices have read people's memory events.
    private let memoryNotices: ProjectionOffset
    private let setup: TurgaiSetupStore
    /// Where the main web app is served, once the cluster runs.
    /// The web server Turgai's routes are handed to once it has started.
    private let web: TurgaiWebServer
    private let api: APIConfiguration
    /// What the node's log shows.
    private let logLevel: Logger.Level

    init(
        environment: [String: String],
        workspaceRoot: String,
        turgaiDirectory: URL,
        persistence: TurgaiPersistence,
        agentCredentials: AgentCredentialStore,
        requestLimits: RequestLimitStore,
        channelSecrets: ChannelSecretStore,
        linking: PersonLinking,
        auth: TurgaiAuth,
        spaceDirectory: SpaceDirectoryStorage,
        conversationDirectory: ConversationDirectoryStorage,
        memoryNotices: ProjectionOffset,
        setup: TurgaiSetupStore,
        web: TurgaiWebServer,
        api: APIConfiguration,
        logLevel: Logger.Level
    ) {
        self.environment = environment
        self.workspaceRoot = workspaceRoot
        self.turgaiDirectory = turgaiDirectory
        self.persistence = persistence
        self.agentCredentials = agentCredentials
        self.requestLimits = requestLimits
        self.channelSecrets = channelSecrets
        self.linking = linking
        self.auth = auth
        self.spaceDirectory = spaceDirectory
        self.conversationDirectory = conversationDirectory
        self.memoryNotices = memoryNotices
        self.setup = setup
        self.web = web
        self.api = api
        self.logLevel = logLevel
    }

    func run() async throws {
        let configuration = try TurgaiWebConfiguration.load(directory: turgaiDirectory)
        guard configuration.isReady else {
            throw ValidationError("Turgai onboarding is incomplete.")
        }

        // A bot's endpoint carries its own context window, read with the bot on each turn.
        let runtimeConfiguration = HailRuntimeConfiguration()
        let endpointFactory = AgentModelEndpointFactory(
            credentials: agentCredentials, transports: requestLimits.transports)
        let modelEndpointProvider: AgentRuntimePlugin.ModelEndpointProvider = { request, system in
            let bot = try await Self.bot(of: request.agentID, on: system)
            guard let model = try? AgentModel(request.model), try bot.model.agentModel == model else { return nil }
            return try await endpointFactory.endpoint(
                for: bot.model,
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
            environment: environment
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
            // The tools every node has: a turn's, and those object code calls, each effect decided
            // by the space of whoever it's on behalf of, as things are then.
            let nodeTools = NodeTools(
                searchBackend: try Self.makeSearchBackend(environment: environment),
                authority: { system in TurgaiAuthority(deciding: .bySpace(system)) })
            let userToolRegistry = Self.userToolRegistry(in: userToolsDirectory)
            let turnTools = TurnToolSources(
                endpointFactory: endpointFactory,
                runtimeConfiguration: runtimeConfiguration,
                nodeTools: nodeTools, workspaceRoot: workspaceRoot,
                wasmRunnerURL: wasmRunnerURL, userToolRegistry: userToolRegistry, linking: linking)
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
                modelSelectionProvider: { request, system in
                    ModelConfiguration(
                        model: try await Self.bot(of: request.agentID, on: system).model.agentModel)
                },
                definitionProvider: { spawnConfig, system in
                    try await Self.definition(for: spawnConfig, on: system)
                },
                turnToolsProvider: { context, actorSystem in
                    try await turnTools.tools(for: context, on: actorSystem)
                },
                // No agent has an authority of its own: what a turn may do, its space decides.
                authority: { system in TurgaiAuthority(deciding: .bySpace(system)) }
            )
            // The plugin is the stores' long-term owner: it receives the
            // instances built above and hosts them for every journaled actor.
            let journalPlugin = ClusterJournalPlugin(
                factory: { _ in eventStore },
                snapshotFactory: { _ in snapshotStore }
            )
            let workflowsPlugin = DurableWorkflowsPlugin()
            let channelRuntimePlugin = TurgaiChannelRuntimePlugin(
                secrets: channelSecrets,
                linking: linking
            )
            // How each platform's connections run, when a space runs one.
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
                // Whether a call may use an object, the caller's space decides, as things are then.
                settings.checkObjectAccess(
                    deciding: ObjectCallDecisions(decide: Space.decides, opening: Space.opens))
                settings.plugins.install(plugin: journalPlugin)
                settings.plugins.install(plugin: runtimePlugin)
                settings.plugins.install(plugin: workflowsPlugin)
                // What runs by itself, kept going by its node, and how each kind comes back after a
                // restart: a connection's run is told by its space how to run now; an object comes
                // back as its own work, which may what its space says then.
                settings.plugins.install(plugin: RunningActors(recovering: [DynamicObject.recovery]))
                settings.plugins.install(plugin: channelRuntimePlugin)
                settings.plugins.install(plugin: ToolsAPIPlugin(nodeTools.api))
            }

            try await system.cluster.joined(endpoint: system.cluster.endpoint, within: .seconds(10))
            // The space and conversation directories and the memory passes, one of each in the
            // cluster, run here, beside the journal they read.
            let spaceDirectory = spaceDirectory
            _ = try await system.singleton.host(SpaceDirectory.self, name: SpaceDirectory.singletonName) {
                SpaceDirectory(actorSystem: $0, storage: spaceDirectory, journal: eventStore)
            }
            let conversationDirectory = conversationDirectory
            _ = try await system.singleton.host(ConversationDirectory.self, name: ConversationDirectory.singletonName) {
                ConversationDirectory(actorSystem: $0, storage: conversationDirectory, journal: eventStore)
            }
            let memoryNotices = memoryNotices
            _ = try await system.singleton.host(MemoryNotices.self, name: MemoryNotices.singletonName) {
                MemoryNotices(actorSystem: $0, storage: memoryNotices, journal: eventStore)
            }
            // The shared production dependency facade for tool effects. The
            // generic parameter is only a carrier; the stored virtual-actor
            // actions serve every effect type.
            ActorSystemDependency<ChatSayEffect>.prepare(
                .live(
                    on: system,
                    models: ChatModels(
                        endpoints: endpointFactory,
                        temperature: runtimeConfiguration.temperature,
                        ollamaKeepAlive: runtimeConfiguration.ollamaKeepAlive)))
            let virtualNode = await VirtualNode(actorSystem: system)
            // What's due, for whoever set it: its owner is told when it's due.
            let scheduleWorker = await DurableActivityDispatchWorker<ScheduleWorkflow>(
                actorSystem: system,
                activities: FiringActivities()
            )
            let timerWorker = await DurableActivityDispatchWorker<TimerWorkflow>(
                actorSystem: system,
                activities: FiringActivities()
            )
            let memoryReadWorker = await DurableActivityDispatchWorker<MemoryReadWorkflow>(
                actorSystem: system,
                activities: MemoryReadActivities()
            )
            let clusterService = TurgaiClusterService(
                system: system,
                virtualNode: virtualNode,
                scheduleWorker: scheduleWorker,
                timerWorker: timerWorker,
                memoryReadWorker: memoryReadWorker
            )

            let logger = system.log
            let auth = auth
            let setup = setup
            // Each part starts on its own: none waits for another, so a slow or failing one holds
            // up nothing else, and messages are taken from the start.
            let parts: [Startup] = [
                Startup("workflows", logger: logger) {
                    try await system.workflows.recoverAll(ofType: ScheduleWorkflow.self)
                    try await system.workflows.recoverAll(ofType: TimerWorkflow.self)
                    try await system.workflows.recoverAll(ofType: MemoryReadWorkflow.self)
                },
                // What ran by itself when the node stopped: each comes back by its own id.
                Startup("running actors", logger: logger) {
                    await system.runningActors.recover()
                },
                // The first space setting up chose, made by whoever set Turgai up, as anyone makes a
                // space; then setting up holds it no more.
                Startup("first space", logger: logger) {
                    guard let first = await setup.firstSpace else { return }
                    let space = try await Space.identified(by: first.id, on: system)
                    if try await space.status() == nil {
                        try await space.make(
                            named: first.name, by: first.maker, bot: first.bot)
                    }
                    try await setup.firstSpaceMade()
                },
            ]

            // The main web app, on the cluster: last, so it stops first, and no request reaches a
            // draining cluster.
            let webApp = try TurgaiMainWebApp(
                auth: auth, directory: turgaiDirectory,
                agentCredentials: agentCredentials, requestLimits: requestLimits, channelSecrets: channelSecrets,
                setup: setup, system: system, journal: eventStore,
                linking: linking, apiConfiguration: api)
            let router = Router(context: BasicWebSocketRequestContext.self)
            router.addMiddleware { FileMiddleware(TurgaiWebAssets.publicRoot, searchForIndexHtml: false) }
            webApp.registerRoutes(on: router)

            // The web server answers with Turgai's routes from here on: a page waiting for it to start
            // gets it on its next request.
            web.serve(router)
            logger.info("Turgai is ready")
            logger.info("Workspace: \(workspaceRoot)")
            let serviceGroup = ServiceGroup(
                configuration: ServiceGroupConfiguration(
                    services: [.init(service: clusterService)]
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
    /// They run what's due: told to whoever set it.
    let scheduleWorker: DurableActivityDispatchWorker<ScheduleWorkflow>
    let timerWorker: DurableActivityDispatchWorker<TimerWorkflow>
    let memoryReadWorker: DurableActivityDispatchWorker<MemoryReadWorkflow>

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
    /// The bot an agent runs as, as its space has it now: the bot its role names, in the space its
    /// context is in; a user's tool thinks as the bot that called it.
    static func bot(of agentID: AgentID, on system: ClusterSystem) async throws -> Bot {
        // A user's tool thinks with the bot that called it, in its space.
        let context = AgentContext(agentID.contextID)
        let role = if case .toolRun(_, let caller, _, _)? = context { caller } else { agentID.role }
        guard let id = BotID(role: role.rawValue) else { throw AgentBotError.notABot(role) }
        guard let space = context?.space else { throw AgentBotError.inNoSpace(agentID) }
        guard let bot = try await Space.identified(by: space, on: system).bot(id) else {
            throw AgentBotError.noSuchBot(id, in: space)
        }
        return bot
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
        switch agentID.role {
        case .toolRun:
            AgentSpawnConfig(agentID: agentID, interruptedTurns: .close, snapshotPolicy: .disabled)
        default:
            // Profile agents: their Conversation owns recovery and
            // starts exactly one model run after its own journal
            // replays; Hail resuming too would be a second driver.
            AgentSpawnConfig(agentID: agentID, interruptedTurns: .close)
        }
    }

    /// What an agent is: its bot's instructions, or a helper's fixed task.
    static func definition(for spawnConfig: AgentSpawnConfig, on system: ClusterSystem) async throws
        -> AgentDefinition?
    {
        let role = spawnConfig.agentID.role
        guard role != .toolRun else {
            return AgentDefinition(
                role: role,
                behavior: .init(
                    systemPrompt:
                        "You are an isolated helper agent. Follow the supplied task, return only the useful result, and do not perform side effects.",
                    execution: AgentExecutionPolicy(sandbox: .readOnly, approvalPolicy: .onRequest)))
        }
        // The bot's own instructions, blank unless its space writes some. What the agent can do
        // comes with its tools and pages, not from here.
        let bot = try await bot(of: spawnConfig.agentID, on: system)
        return AgentDefinition(
            role: role, behavior: .init(systemPrompt: bot.instructions.trimmed(), execution: .autonomousWorkspace))
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
    let endpointFactory: AgentModelEndpointFactory
    let runtimeConfiguration: HailRuntimeConfiguration
    let nodeTools: NodeTools
    let workspaceRoot: String
    let wasmRunnerURL: URL?
    let userToolRegistry: UserToolRegistry
    let linking: PersonLinking

    func tools(for context: AgentTurnContext, on actorSystem: ClusterSystem) async throws -> TurnTools {
        var tools = try await ConversationTools.make(
            context: context,
            nodeTools: nodeTools,
            workspaceRoot: workspaceRoot,
            wasmRunnerURL: wasmRunnerURL,
            userTools: userToolRegistry,
            actorSystem: actorSystem,
            linking: linking,
            includeConversationTools: context.agentID.role != .toolRun
        )
        // Hail's files and agent messaging, for the agents granted them.
        if context.agentID.role != .toolRun {
            tools.tools =
                try await actorSystem.agentRuntime.agentTools(for: context, actorSystem: actorSystem)
                + tools.tools
        }
        return tools
    }
}
