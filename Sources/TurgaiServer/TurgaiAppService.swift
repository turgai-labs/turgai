import ArgumentParser
import DiscoverableActors
import DistributedCluster
import DurableWorkflows
import EventSourcing
import Hail
import Logging
import PostgresEventStore
import PostgresNIO
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
    private var provider: (@Sendable () async -> [TurgaiAgentRuntimeSnapshot])?

    func setProvider(
        _ provider: @escaping @Sendable () async -> [TurgaiAgentRuntimeSnapshot]
    ) {
        self.provider = provider
    }

    func snapshots() async -> [TurgaiAgentRuntimeSnapshot] {
        guard let provider else { return [] }
        return await provider()
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
    private let agentProfiles: TurgaiAgentProfileStore
    private let agentCredentials: AgentCredentialStore
    private let requestLimits: RequestLimitStore
    private let channelSecrets: ChannelSecretStore
    private let runtimeSnapshotSource: TurgaiRuntimeSnapshotSource
    private let objectCatalogSource: TurgaiObjectCatalogSource
    private let webChatBridge: TurgaiWebChatBridge

    init(
        environment: [String: String],
        workspaceRoot: String,
        turgaiDirectory: URL,
        agentProfiles: TurgaiAgentProfileStore,
        agentCredentials: AgentCredentialStore,
        requestLimits: RequestLimitStore,
        channelSecrets: ChannelSecretStore,
        runtimeSnapshotSource: TurgaiRuntimeSnapshotSource,
        objectCatalogSource: TurgaiObjectCatalogSource,
        webChatBridge: TurgaiWebChatBridge
    ) {
        self.environment = environment
        self.workspaceRoot = workspaceRoot
        self.turgaiDirectory = turgaiDirectory
        self.agentProfiles = agentProfiles
        self.agentCredentials = agentCredentials
        self.requestLimits = requestLimits
        self.channelSecrets = channelSecrets
        self.runtimeSnapshotSource = runtimeSnapshotSource
        self.objectCatalogSource = objectCatalogSource
        self.webChatBridge = webChatBridge
    }

    func run() async throws {
        let configuration = try TurgaiWebConfiguration.load(directory: turgaiDirectory)
        guard configuration.isReady else {
            throw ValidationError("Turgai onboarding is incomplete.")
        }

        guard let defaultAgentProfile = await agentProfiles.defaultProfile() else {
            throw ValidationError("At least one agent must be configured.")
        }
        let configuredProfiles = await agentProfiles.profiles()
        let modelContextWindows: [AgentModel: Int] = configuredProfiles.reduce(into: [:]) {
            (windows: inout [AgentModel: Int], profile: TurgaiAgentProfile) in
            windows[profile.model] = profile.contextWindow
        }
        let runtimeConfiguration = HailRuntimeConfiguration(
            contextWindow: defaultAgentProfile.contextWindow,
            modelContextWindows: modelContextWindows,
            contextWindowProvider: { model, agentID in
                guard let profile = await Self.profile(of: agentID, in: agentProfiles), profile.model == model else {
                    return nil
                }
                return profile.contextWindow
            }
        )
        let endpointFactory = AgentModelEndpointFactory(
            credentials: agentCredentials, transports: requestLimits.transports)
        let modelEndpointProvider: ModelEndpointProvider = { request in
            guard let model = try? AgentModel(request.model),
                let profile = await Self.profile(of: request.agentID, in: agentProfiles), profile.model == model
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
        let persistence = try TurgaiPersistence(
            configuration: storageConfiguration,
            postgresPassword: configuration.postgresPassword
        )

        try await withThrowingTaskGroup(of: Void.self) { persistenceTasks in
            // Each store is built exactly once, here at the composition root:
            // the same instance serves boot recovery and the journal plugin.
            let stores: Stores
            switch persistence.backend {
            case .file(let client):
                stores = Self.stores(on: client)
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
            let loadPersistedConversationIDs = stores.conversationIDs
            let discoverChannelIDs = stores.channelIDs
            let persistedConversationIDs = try await loadPersistedConversationIDs()
            let userToolsDirectory =
                turgaiDirectory
                .appendingPathComponent("tools", isDirectory: true)
            let wasmRunnerURL = WasmRunnerLocator.executableURL(environment: environment)
            let attachmentResolver = AttachmentResolver()
            let searchBackend = try Self.makeSearchBackend(environment: environment)
            let userToolRegistry = Self.userToolRegistry(in: userToolsDirectory)
            let turnTools = TurnToolSources(
                agentProfiles: agentProfiles, endpointFactory: endpointFactory,
                runtimeConfiguration: runtimeConfiguration,
                attachmentResolver: attachmentResolver, searchBackend: searchBackend, workspaceRoot: workspaceRoot,
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
                authorityProvider: { spawnConfig, workspace in Self.authority(for: spawnConfig, in: workspace) }
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
                attachments: attachmentResolver,
                loadPersistedConversationIDs: loadPersistedConversationIDs
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
            }

            try await system.cluster.joined(endpoint: system.cluster.endpoint, within: .seconds(10))
            // The shared production dependency facade for tool effects. The
            // generic parameter is only a carrier; the stored workflows and
            // virtual-actor actions serve every effect type.
            ActorSystemDependency<CreateTimerEffect>.prepare(.live(on: system))
            let virtualNode = await VirtualNode(actorSystem: system)
            // The objects models made: started again after a restart, each on behalf of whoever
            // made it, so what they follow and run keeps going.
            try await DynamicObjects.resolve(on: system).start()
            let scheduleWorker = await DurableActivityDispatchWorker<ScheduleWorkflow>(
                actorSystem: system,
                activities: ScheduleActivities()
            )
            let scheduleTimerWorker = await DurableActivityDispatchWorker<TimerWorkflow>(
                actorSystem: system,
                activities: TimerActivities()
            )
            let memoryExtractionWorker = await DurableActivityDispatchWorker<MemoryExtractionWorkflow>(
                actorSystem: system,
                activities: MemoryExtractionActivities(endpointFactory: endpointFactory)
            )
            try await system.workflows.recoverAll(ofType: ScheduleWorkflow.self)
            try await system.workflows.recoverAll(ofType: TimerWorkflow.self)
            try await system.workflows.recoverAll(ofType: MemoryExtractionWorkflow.self)
            let channelRuntime = try await system.turgaiChannelRuntime.dependencies()
            let connections = channelRuntime.connections
            await objectCatalogSource.set(channelRuntime.objectCatalog)
            await webChatBridge.install(
                connections,
                discoverChannelIDs: discoverChannelIDs,
                actorSystem: system,
                persistedConversationIDs: persistedConversationIDs
            )
            for channelID in try await discoverChannelIDs() {
                do {
                    _ = try await TelegramChannel.resolve(on: system, channelID: channelID)
                } catch {
                    system.log.warning(
                        "Could not recover Telegram channel actor",
                        metadata: [
                            "channel": .string(channelID.uuidString),
                            "error": .string(String(describing: error)),
                        ]
                    )
                }
            }
            let runtimeSnapshotProvider: @Sendable () async -> [TurgaiAgentRuntimeSnapshot] = {
                await Self.runtimeSnapshots(on: system)
            }
            await runtimeSnapshotSource.setProvider(runtimeSnapshotProvider)
            let clusterService = TurgaiClusterService(
                system: system,
                virtualNode: virtualNode,
                scheduleWorker: scheduleWorker,
                scheduleTimerWorker: scheduleTimerWorker,
                memoryExtractionWorker: memoryExtractionWorker,
                discoverChannelIDs: discoverChannelIDs
            )

            let logger = system.log
            logger.info("Turgai is ready")
            logger.info("Workspace: \(workspaceRoot)")
            let services: [any Service] = [clusterService, connections]
            let serviceGroup = ServiceGroup(
                services: services,
                logger: logger
            )
            try await serviceGroup.run()
            persistenceTasks.cancelAll()
        }
    }

    private static func conversationIDs(persistenceIDs: [String]) -> [ConversationID] {
        persistenceIDs.compactMap { ConversationPersistenceID(rawValue: $0)?.conversationID }
    }

    private static func makeSearchBackend(environment: [String: String]) throws -> WebSearchBackend {
        let raw = environment["TURGAI_SEARCH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

struct TurgaiClusterService: Service {
    let system: ClusterSystem
    let virtualNode: VirtualNode
    let scheduleWorker: DurableActivityDispatchWorker<ScheduleWorkflow>
    let scheduleTimerWorker: DurableActivityDispatchWorker<TimerWorkflow>
    let memoryExtractionWorker: DurableActivityDispatchWorker<MemoryExtractionWorkflow>
    let discoverChannelIDs: @Sendable () async throws -> [UUID]

    func run() async throws {
        let (shutdownRequests, shutdownContinuation) = AsyncStream<Void>.makeStream()
        let recoveryTask = Task {
            await recoverChannelsAfterNodeLoss()
        }
        defer {
            shutdownContinuation.finish()
        }

        do {
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
                        recoveryTask.cancel()
                        await recoveryTask.value
                        if gracefulShutdownRequested || Task.isCancelled {
                            try system.shutdown()
                        }
                    } catch {
                        recoveryTask.cancel()
                        await recoveryTask.value
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
        } catch {
            recoveryTask.cancel()
            await recoveryTask.value
            throw error
        }
    }

    private func recoverChannelsAfterNodeLoss() async {
        for await event in system.cluster.events {
            guard !Task.isCancelled, !system.isTerminated else { return }
            let requiresRecovery: Bool
            switch event {
            case .snapshot(let membership):
                requiresRecovery = !membership.members(atLeast: .down).isEmpty
            case .membershipChange(let change):
                requiresRecovery = change.isDown || change.isRemoval
            default:
                requiresRecovery = false
            }
            guard requiresRecovery, !Task.isCancelled, !system.isTerminated else { continue }
            await recoverChannels()
        }
    }

    private func recoverChannels() async {
        guard !Task.isCancelled, !system.isTerminated else { return }
        do {
            let channelIDs = try await discoverChannelIDs()
            var unresolved: [UUID] = []
            for id in channelIDs {
                guard !Task.isCancelled, !system.isTerminated else { return }
                do {
                    _ = try await TelegramChannel.resolve(on: system, channelID: id)
                } catch is CancellationError {
                    return
                } catch {
                    unresolved.append(id)
                    system.log.warning(
                        "Channel activation is waiting for virtual actor placement recovery",
                        metadata: [
                            "channel": .string(id.uuidString),
                            "error": .string(String(describing: error)),
                        ]
                    )
                }
            }
            if !unresolved.isEmpty {
                system.log.warning(
                    "Some channels could not be resolved during node recovery",
                    metadata: ["count": .string(String(unresolved.count))]
                )
            }
        } catch is CancellationError {
            return
        } catch {
            system.log.warning(
                "Could not discover channels during node recovery",
                metadata: ["error": .string(String(describing: error))]
            )
        }
    }
}

// MARK: How agents are built

extension TurgaiAppService {
    /// The profile an agent runs as: its own, or the default one for a helper.
    static func profile(of agentID: AgentID, in agentProfiles: TurgaiAgentProfileStore) async -> TurgaiAgentProfile? {
        let role = agentID.role.rawValue
        return role == "user-tool" ? await agentProfiles.defaultProfile() : await agentProfiles.profile(id: role)
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
            guard let currentDefault = await agentProfiles.defaultProfile() else {
                throw TurgaiModelSelectionError.missingProfile(
                    TurgaiAgentProfileStore.defaultProfileID
                )
            }
            return ModelConfiguration(
                model: currentDefault.model,
                reasoningEffort: currentDefault.reasoningEffort
            )
        }
        guard let profile = await agentProfiles.profile(id: role) else {
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
        case .userTool: profile = await agentProfiles.defaultProfile()
        case .profile: profile = await agentProfiles.profile(id: role)
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
            profile.instructions.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        let personaInstructions =
            profile.persona?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
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

    /// What an agent may do: a helper nothing outside, a profile agent its workspace and Turgai's
    /// own effects.
    static func authority(for spawnConfig: AgentSpawnConfig, in workspace: AgentWorkspace) -> any Authority {
        if spawnConfig.agentID.role.rawValue == "user-tool" {
            return CompositeAuthority()
                .granting(for: FileEffect.self) { _ in
                    .denied("prompt helpers cannot access files")
                }
                .granting(for: TerminalEffect.self) { _ in
                    .denied("prompt helpers cannot run terminal commands")
                }
                .granting(for: ProcessEffect.self) { _ in
                    .denied("prompt helpers cannot spawn processes")
                }
                .granting(for: NetworkEffect.self) { _ in
                    .denied("prompt helpers cannot access the network")
                }
                .granting(for: CoordinationEffect.self) { _ in
                    .denied("prompt helpers cannot coordinate with other agents")
                }
                .grantingAll(for: ClockEffect.self)
        }
        return
            CompositeAuthority
            .workspaceDefault(root: workspace.rootPath)
            .grantingAll(for: UserWorkflowEffect.self)
            .grantingAll(for: CreateScheduleEffect.self)
            .grantingAll(for: ReplaceScheduleEffect.self)
            .grantingAll(for: CancelScheduleEffect.self)
            .grantingAll(for: ListSchedulesEffect.self)
            .grantingAll(for: TriggerScheduleEffect.self)
            .grantingAll(for: CreateTimerEffect.self)
            .grantingAll(for: ReplaceTimerEffect.self)
            .grantingAll(for: CancelTimerEffect.self)
            .grantingAll(for: ListTimersEffect.self)
            // Actions that aren't safe also ask the user, inside the effect.
            .grantingAll(for: FindObjectsEffect.self)
            .grantingAll(for: ListObjectsEffect.self)
            .grantingAll(for: MakeObjectEffect.self)
            .grantingAll(for: ToolPageEffect.self)
            .grantingAll(for: EditObjectEffect.self)
            .grantingAll(for: UseObjectEffect.self)
            .grantingAll(for: RemoveObjectEffect.self)
            .grantingAll(for: InvokeObjectEffect.self)
            .grantingAll(for: RecallEffect.self)
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

    /// What each running profile agent is doing, for the dashboard.
    static func runtimeSnapshots(on system: ClusterSystem) async -> [TurgaiAgentRuntimeSnapshot] {
        let entries = (try? await system.agentRuntime.allAgents()) ?? []
        return await withTaskGroup(
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
        let conversationIDs: @Sendable () async throws -> [ConversationID]
        let channelIDs: @Sendable () async throws -> [UUID]
    }

    /// The journal in files.
    static func stores(on client: FileClient) -> Stores {
        let reader = FileJournalReader(client: client)
        return Stores(
            events: FileEventStore(client: client),
            snapshots: FileSnapshotStore(client: client),
            conversationIDs: {
                Self.conversationIDs(
                    persistenceIDs: try await reader.persistenceIDs(withPrefix: ConversationPersistenceID.prefix))
            },
            channelIDs: {
                try await reader.persistenceIDs(withPrefix: TelegramChannel.persistencePrefix)
                    .compactMap(TelegramChannel.channelID(from:))
            })
    }

    /// The journal in PostgreSQL, its tables set up.
    static func stores(on client: PostgresClient) async throws -> Stores {
        let events = PostgresEventStore(client: client)
        let snapshots = PostgresSnapshotStore(client: client)
        try await events.setupDatabase()
        try await snapshots.setupDatabase()
        let reader = PostgresJournalReader(client: client)
        return Stores(
            events: events,
            snapshots: snapshots,
            conversationIDs: { try await reader.conversationIDs() },
            channelIDs: {
                try await reader.persistenceIDs(withPrefix: TelegramChannel.persistencePrefix)
                    .compactMap(TelegramChannel.channelID(from:))
            })
    }
}

/// What a turn's tools are built from: each turn gets them anew, for the agent taking it.
struct TurnToolSources: Sendable {
    let agentProfiles: TurgaiAgentProfileStore
    let endpointFactory: AgentModelEndpointFactory
    let runtimeConfiguration: HailRuntimeConfiguration
    let attachmentResolver: AttachmentResolver
    let searchBackend: WebSearchBackend
    let workspaceRoot: String
    let wasmRunnerURL: URL?
    let userToolRegistry: UserToolRegistry

    func tools(for context: AgentTurnContext, on actorSystem: ClusterSystem) async throws -> TurnTools {
        let objectCatalog = try await actorSystem.turgaiChannelRuntime.dependencies().objectCatalog
        // An object's Swift is written by the agent's own model, in a session of its own.
        let writer: ObjectWriter? =
            if let profile = await agentProfiles.profile(id: context.agentID.role.rawValue) {
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
            attachmentResolver: attachmentResolver,
            searchBackend: searchBackend,
            workspaceRoot: workspaceRoot,
            wasmRunnerURL: wasmRunnerURL,
            userTools: userToolRegistry,
            approval: ChannelToolApproval(
                actorSystem: actorSystem, agentRole: context.agentID.role.rawValue),
            actorSystem: actorSystem,
            objectCatalog: objectCatalog,
            writer: writer,
            // Every enabled profile's agent can be asked, as an object.
            agents: await agentProfiles.profiles().filter { $0.availability == .enabled }.map {
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
