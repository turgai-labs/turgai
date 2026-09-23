import ArgumentParser
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
    private let channelSecrets: ChannelSecretStore
    private let runtimeSnapshotSource: TurgaiRuntimeSnapshotSource
    private let webChatBridge: TurgaiWebChatBridge

    init(
        environment: [String: String],
        workspaceRoot: String,
        turgaiDirectory: URL,
        agentProfiles: TurgaiAgentProfileStore,
        channelSecrets: ChannelSecretStore,
        runtimeSnapshotSource: TurgaiRuntimeSnapshotSource,
        webChatBridge: TurgaiWebChatBridge
    ) {
        self.environment = environment
        self.workspaceRoot = workspaceRoot
        self.turgaiDirectory = turgaiDirectory
        self.agentProfiles = agentProfiles
        self.channelSecrets = channelSecrets
        self.runtimeSnapshotSource = runtimeSnapshotSource
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
        let modelContextWindows = configuredProfiles.reduce(into: [AgentModel: Int]()) { result, profile in
            result[profile.model] = profile.contextWindow
        }
        let runtimeConfiguration = HailRuntimeConfiguration(
            contextWindow: defaultAgentProfile.contextWindow,
            modelContextWindows: modelContextWindows,
            contextWindowProvider: { model, agentID in
                let role = agentID.role.rawValue
                let profile: TurgaiAgentProfile?
                if role == "user-tool" {
                    profile = await agentProfiles.defaultProfile()
                } else {
                    profile = await agentProfiles.profile(id: role)
                }
                guard let profile, profile.model == model else { return nil }
                return profile.contextWindow
            }
        )
        let modelEndpointProvider: ModelEndpointProvider = { request in
            guard let model = try? AgentModel(request.model) else {
                return nil
            }
            let profile: TurgaiAgentProfile
            if request.agentID.role.rawValue != "user-tool" {
                guard
                    let configuredProfile = await agentProfiles.profile(
                        id: request.agentID.role.rawValue
                    )
                else {
                    return nil
                }
                profile = configuredProfile
            } else {
                guard let currentDefault = await agentProfiles.defaultProfile() else { return nil }
                profile = currentDefault
            }
            switch model.provider {
            case .ollama:
                guard case .ollama(let baseURL) = profile.providerConfiguration else {
                    return nil
                }
                return OllamaEndpoint(
                    model: model.id.rawValue,
                    baseURL: baseURL,
                    temperature: runtimeConfiguration.temperature,
                    numContext: profile.contextWindow,
                    keepAlive: runtimeConfiguration.ollamaKeepAlive,
                    think: request.reasoning?.encoding == .disabled ? false : nil
                )
            default:
                return nil
            }
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
            let eventStore: any EventStore
            let snapshotStore: any SnapshotStore
            let persistedConversationIDs: [ConversationID]
            let discoverChannelIDs: @Sendable () async throws -> [UUID]
            let loadPersistedConversationIDs: @Sendable () async throws -> [ConversationID]
            switch persistence.backend {
            case .file(let client):
                let fileEventStore = FileEventStore(client: client)
                let fileJournalReader = FileJournalReader(client: client)
                eventStore = fileEventStore
                snapshotStore = FileSnapshotStore(client: client)
                loadPersistedConversationIDs = {
                    let ids = try await fileJournalReader.persistenceIDs(
                        withPrefix: ConversationPersistenceID.prefix
                    )
                    return Self.conversationIDs(persistenceIDs: ids)
                }
                persistedConversationIDs = try await loadPersistedConversationIDs()
                discoverChannelIDs = {
                    try await fileJournalReader.persistenceIDs(
                        withPrefix: TelegramChannel.persistencePrefix
                    )
                    .compactMap(TelegramChannel.channelID(from:))
                }
            case .postgres(let client):
                // A PostgreSQL query naturally waits until PostgresClient.run
                // is active. The client task remains structured around the
                // whole app phase and is cancelled when the app exits.
                persistenceTasks.addTask {
                    await client.run()
                }
                let postgresEventStore = PostgresEventStore(client: client)
                let postgresSnapshotStore = PostgresSnapshotStore(client: client)
                try await postgresEventStore.setupDatabase()
                try await postgresSnapshotStore.setupDatabase()
                eventStore = postgresEventStore
                snapshotStore = postgresSnapshotStore
                let postgresJournalReader = PostgresJournalReader(client: client)
                loadPersistedConversationIDs = {
                    try await postgresJournalReader.conversationIDs()
                }
                persistedConversationIDs = try await loadPersistedConversationIDs()
                discoverChannelIDs = {
                    try await postgresJournalReader.persistenceIDs(
                        withPrefix: TelegramChannel.persistencePrefix
                    ).compactMap(TelegramChannel.channelID(from:))
                }
            }
            let userToolsDirectory =
                turgaiDirectory
                .appendingPathComponent("tools", isDirectory: true)
            let wasmRunnerURL = WasmRunnerLocator.executableURL(environment: environment)
            let attachmentResolver = AttachmentResolver()
            let searchBackend = try Self.makeSearchBackend(environment: environment)
            let userToolLogger = Logger(label: "turgai.usertools")
            let userToolRegistry = UserToolRegistry(
                directory: userToolsDirectory
            ) { issue in
                userToolLogger.warning(
                    "User tool issue",
                    metadata: [
                        "source": .string(issue.source.lastPathComponent),
                        "reason": .string(String(describing: issue.reason)),
                    ]
                )
            }
            let runtimePlugin = try runtimeConfiguration.makeAgentRuntimePlugin(
                workspaceRoot: workspaceRoot,
                modelEndpointProvider: modelEndpointProvider,
                modelSelectionProvider: { request in
                    let role = request.agentID.role.rawValue
                    if role == "user-tool" {
                        guard let currentDefault = await agentProfiles.defaultProfile() else {
                            throw TurgaiModelSelectionError.missingProfile(
                                TurgaiAgentProfileStore.defaultProfileID
                            )
                        }
                        return ModelConfiguration(
                            model: currentDefault.model,
                            reasoningEffort: currentDefault.reasoningEffort,
                            sessionConfigurationIdentity: Self.sessionConfigurationIdentity(
                                for: currentDefault
                            )
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
                        reasoningEffort: profile.reasoningEffort,
                        sessionConfigurationIdentity: Self.sessionConfigurationIdentity(
                            for: profile
                        )
                    )
                },
                definitionProvider: { spawnConfig in
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
                        systemPrompt = [
                            "You are a local conversational assistant. Be helpful, concise, honest, and natural.",
                            "Do not assume the user's physical location. The supplied date/time uses Turgai's fixed operating timezone and is not evidence of where the user is. Do not derive a place from the server's timezone, locale, IP address, language, or current date/time. For location-dependent requests such as weather, ask for a city or place unless the user provided one or it is explicitly present in saved personal memory.",
                            customInstructions,
                            MemoryRetrieval.capabilityInstruction,
                        ]
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n\n")
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
                },
                turnToolsProvider: { context, actorSystem in
                    ConversationTools.make(
                        context: context,
                        attachmentResolver: attachmentResolver,
                        searchBackend: searchBackend,
                        workspaceRoot: workspaceRoot,
                        wasmRunnerURL: wasmRunnerURL,
                        userTools: userToolRegistry,
                        approval: ChannelToolApproval(actorSystem: actorSystem),
                        actorSystem: actorSystem,
                        includeConversationTools: context.agentID.role.rawValue != "user-tool"
                    )
                },
                authorityProvider: { spawnConfig, workspace in
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
                }
            )
            // The plugin is the stores' long-term owner: it receives the
            // instances built above and hosts them for every journaled actor.
            let journalPlugin = ClusterJournalPlugin(
                factory: { _ in eventStore },
                snapshotFactory: { _ in snapshotStore }
            )
            let virtualActorsPlugin = ClusterVirtualActorsPlugin()
            let workflowsPlugin = DurableWorkflowsPlugin()
            let channelRuntimePlugin = TurgaiChannelRuntimePlugin(
                agentProfiles: agentProfiles,
                secrets: channelSecrets,
                attachments: attachmentResolver,
                loadPersistedConversationIDs: loadPersistedConversationIDs
            )

            let system = await ClusterSystem("turgai") { settings in
                settings.bindHost = "127.0.0.1"
                settings.bindPort = PortFinder.findAvailablePort(host: "127.0.0.1")
                settings.discovery = nil
                settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)
                settings.plugins.install(plugin: ClusterSingletonPlugin())
                settings.plugins.install(plugin: virtualActorsPlugin)
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
            let scheduleWorker = await DurableActivityDispatchWorker<ScheduleWorkflow>(
                actorSystem: system
            )
            let scheduleTimerWorker = await DurableActivityDispatchWorker<TimerWorkflow>(
                actorSystem: system
            )
            try await system.workflows.recoverAll(ofType: ScheduleWorkflow.self)
            try await system.workflows.recoverAll(ofType: TimerWorkflow.self)
            let channelRuntime = try await system.turgaiChannelRuntime.dependencies()
            let connections = channelRuntime.connections
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
                let entries = (try? await system.agentRuntime.allAgents()) ?? []
                return await withTaskGroup(
                    of: TurgaiAgentRuntimeSnapshot?.self, returning: [TurgaiAgentRuntimeSnapshot].self
                ) { group in
                    for entry in entries where entry.role.rawValue != "user-tool" {
                        guard let spawnConfig = entry.spawnConfig else { continue }
                        group.addTask {
                            guard
                                let agent: Agent = try? await system.virtualActors.getActor(
                                    identifiedBy: VirtualActorID(rawValue: entry.agentID.rawValue),
                                    dependency: spawnConfig
                                ), let snapshot = try? await agent.contextSnapshot
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
                                conversationMessageCount: snapshot.conversationMessageCount,
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
            await runtimeSnapshotSource.setProvider(runtimeSnapshotProvider)
            let clusterService = TurgaiClusterService(
                system: system,
                virtualNode: virtualNode,
                scheduleWorker: scheduleWorker,
                scheduleTimerWorker: scheduleTimerWorker,
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

    private static func sessionConfigurationIdentity(
        for profile: TurgaiAgentProfile
    ) -> String {
        [
            profile.id,
            profile.model.identifier,
            profile.reasoningEffort?.rawValue ?? "provider-default",
            String(describing: profile.providerConfiguration),
            String(profile.contextWindow),
        ].joined(separator: "\u{1F}")
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
                let gracefulShutdownRequested = try await withThrowingTaskGroup(of: Bool.self) {
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
                    let result = try await group.next() ?? false
                    group.cancelAll()
                    return result
                }

                // The recovery listener can react to the local node's removal
                // event. Finish it before ClusterSystem.shutdown stops the
                // virtual-actor plugin it uses to resolve channels.
                recoveryTask.cancel()
                await recoveryTask.value
                if gracefulShutdownRequested {
                    _ = try? system.shutdown()
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
            guard !system.isTerminated else { return }
            let requiresRecovery: Bool
            switch event {
            case .snapshot(let membership):
                requiresRecovery = !membership.members(atLeast: .down).isEmpty
            case .membershipChange(let change):
                requiresRecovery = change.isDown || change.isRemoval
            default:
                requiresRecovery = false
            }
            guard requiresRecovery, !system.isTerminated else { continue }
            await recoverChannels()
        }
    }

    private func recoverChannels() async {
        guard !system.isTerminated else { return }
        do {
            let channelIDs = try await discoverChannelIDs()
            var unresolved: [UUID] = []
            for id in channelIDs {
                guard !system.isTerminated else { return }
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
