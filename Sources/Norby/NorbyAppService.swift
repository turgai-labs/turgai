import ArgumentParser
import DistributedCluster
import DurableWorkflows
import EventSourcing
import Hail
import Logging
import NorbyApplication
import NorbyDomain
import NorbyHail
import NorbyMemory
import NorbyPersistence
import NorbyTelegram
import ServiceLifecycle
import TurgaiWeb
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

actor NorbyRuntimeSnapshotSource {
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

struct NorbyAppService: Service, Sendable {
    private let environment: [String: String]
    private let workspaceRoot: String
    private let norbyDirectory: URL
    private let agentProfiles: NorbyAgentProfileStore
    private let runtimeSnapshotSource: NorbyRuntimeSnapshotSource

    init(
        environment: [String: String],
        workspaceRoot: String,
        norbyDirectory: URL,
        agentProfiles: NorbyAgentProfileStore,
        runtimeSnapshotSource: NorbyRuntimeSnapshotSource
    ) {
        self.environment = environment
        self.workspaceRoot = workspaceRoot
        self.norbyDirectory = norbyDirectory
        self.agentProfiles = agentProfiles
        self.runtimeSnapshotSource = runtimeSnapshotSource
    }

    func run() async throws {
        let configuration = try TurgaiWebConfiguration.load(directory: norbyDirectory)
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
        let defaultModel = defaultAgentProfile.model
        let runtimeConfiguration = HailRuntimeConfiguration(
            modelContextWindows: modelContextWindows
        )
        let profilesByID = Dictionary(uniqueKeysWithValues: configuredProfiles.map { ($0.id, $0) })
        let modelEndpointProvider: ModelEndpointProvider = { request in
            guard let model = try? AgentModel(request.model), model.provider == .ollama else {
                return nil
            }
            let profile: NorbyAgentProfile
            if let profileID = Self.profileID(from: request.agentID), profileID != "user-tool" {
                guard let configuredProfile = profilesByID[profileID] else { return nil }
                profile = configuredProfile
            } else {
                profile = defaultAgentProfile
            }
            guard let baseURL = profile.ollamaBaseURL else { return nil }
            return OllamaEndpoint(
                model: model.id.rawValue,
                baseURL: baseURL,
                temperature: runtimeConfiguration.temperature,
                numContext: profile.contextWindow,
                think: request.reasoning?.encoding == .disabled ? false : nil
            )
        }
        guard let storageConfiguration = configuration.storage else {
            throw ValidationError("Storage configuration is missing.")
        }
        let persistenceRuntime = try NorbyPersistenceRuntime(
            configuration: storageConfiguration,
            postgresPassword: configuration.postgresPassword
        )

        try await withThrowingTaskGroup(of: Void.self) { persistenceTasks in
            if let postgresClient = persistenceRuntime.postgresClient {
                persistenceTasks.addTask {
                    await postgresClient.run()
                }
            }
            // A PostgreSQL query naturally waits until PostgresClient.run is
            // active. The client task remains structured around the whole app
            // phase and is cancelled when the app exits.
            try await persistenceRuntime.setupDatabase()
            let conversationJournals = try await persistenceRuntime.conversationJournals()
            let persistedConversationIDs = conversationJournals.map(\.conversationID)
            guard
                let configuredTelegramToken = configuration.telegramToken?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ), !configuredTelegramToken.isEmpty
            else {
                throw ValidationError("Telegram configuration is missing.")
            }

            // Share one Bot API client between transport and dynamic tool
            // approvals so callback handling and approval messages use the same
            // dependency boundary.
            let telegramClient = try TelegramAPIClient.live(token: configuredTelegramToken)
            let telegramApproval = TelegramToolApproval(client: telegramClient)
            let toolApproval: any ToolApproval = telegramApproval

            let userToolsDirectory =
                norbyDirectory
                .appendingPathComponent("tools", isDirectory: true)
            let wasmRunnerURL = WasmRunnerLocator.executableURL(environment: environment)
            let attachmentResolver = AttachmentResolver()
            let searchBackend = try Self.makeSearchBackend(environment: environment)
            let userToolLogger = Logger(label: "norby.usertools")
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
                defaultModel: defaultModel,
                workspaceRoot: workspaceRoot,
                modelEndpointProvider: modelEndpointProvider,
                definitionProvider: { spawnConfig in
                    let role = spawnConfig.agentID.role.rawValue
                    let isUserTool = role == "user-tool"
                    let profile =
                        isUserTool
                        ? defaultAgentProfile
                        : await agentProfiles.profile(id: role)
                    guard let profile, isUserTool || profile.enabled else { return nil }
                    let selectedModel = profile.model
                    let customInstructions =
                        profile.instructions.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                    let personaInstructions: String
                    if let configuredPersona = profile.persona?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ), !configuredPersona.isEmpty {
                        personaInstructions = configuredPersona
                    } else {
                        personaInstructions = NorbyAgentPersona.instructions
                    }
                    let systemPrompt =
                        isUserTool
                        ? "You are an isolated helper agent. Follow the supplied task, return only the useful result, and do not perform side effects."
                        : [
                            "You are a local conversational assistant. Be helpful, concise, honest, and natural.",
                            "Do not assume the user's physical location. The supplied date/time uses Norby's fixed operating timezone and is not evidence of where the user is. Do not derive a place from the server's timezone, locale, IP address, language, or current date/time. For location-dependent requests such as weather, ask for a city or place unless the user provided one or it is explicitly present in saved personal memory.",
                            customInstructions,
                            MemoryRetrieval.capabilityInstruction,
                        ]
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n\n")
                    return AgentDefinition(
                        role: spawnConfig.agentID.role,
                        behavior: .init(
                            systemPrompt: systemPrompt,
                            model: selectedModel,
                            execution: isUserTool
                                ? AgentExecutionPolicy(
                                    sandbox: .readOnly,
                                    approvalPolicy: .onRequest
                                )
                                : .autonomousWorkspace
                        ),
                        persona: isUserTool
                            ? nil
                            : AgentPersona(
                                displayName: profile.name,
                                instructions: personaInstructions
                            )
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
                        approval: toolApproval,
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
            let journalPlugin = ClusterJournalPlugin(
                factory: { _ in persistenceRuntime.eventStore },
                snapshotFactory: { _ in persistenceRuntime.snapshotStore }
            )
            let virtualActorsPlugin = ClusterVirtualActorsPlugin()
            let workflowsPlugin = DurableWorkflowsPlugin()

            let system = await ClusterSystem("norby") { settings in
                settings.bindHost = "127.0.0.1"
                settings.bindPort = PortFinder.findAvailablePort(host: "127.0.0.1")
                settings.discovery = nil
                settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)
                settings.plugins.install(plugin: ClusterSingletonPlugin())
                settings.plugins.install(plugin: virtualActorsPlugin)
                settings.plugins.install(plugin: journalPlugin)
                settings.plugins.install(plugin: runtimePlugin)
                settings.plugins.install(plugin: workflowsPlugin)
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
            let allowedChatIDs = Set(configuration.telegramChatIDs)
            let memoryExtraction: OllamaMemoryConfiguration?
            if defaultModel.provider == .ollama,
                let baseURL = defaultAgentProfile.ollamaBaseURL
            {
                memoryExtraction = OllamaMemoryConfiguration(
                    model: defaultModel.id,
                    baseURL: baseURL
                )
            } else {
                // The background memory extractor is currently Ollama-specific;
                // never pass an OpenAI or Foundation Model ID to that endpoint.
                memoryExtraction = nil
            }
            let connections = NorbyConnections(
                actorSystem: system,
                memoryExtraction: memoryExtraction,
                agentProfiles: agentProfiles
            )
            let telegramService = TelegramService(
                client: telegramClient,
                allowedChatIDs: allowedChatIDs,
                offsetFileURL: norbyDirectory.appendingPathComponent("telegram-offset.txt"),
                connections: connections,
                attachmentResolver: attachmentResolver,
                logger: system.log,
                persistedConversationIDs: persistedConversationIDs,
                callbackHandler: { callback in
                    await telegramApproval.handle(callback)
                }
            )
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
                                phase: snapshot.phase.rawValue,
                                currentTool: snapshot.currentToolName,
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
            let clusterService = NorbyClusterService(
                system: system,
                virtualNode: virtualNode,
                scheduleWorker: scheduleWorker,
                scheduleTimerWorker: scheduleTimerWorker
            )

            let logger = system.log
            logger.info("Telegram enabled")
            if !allowedChatIDs.isEmpty {
                logger.info("Telegram chat allow-list enabled")
            }
            logger.info("Norby is ready")
            logger.info("Workspace: \(workspaceRoot)")
            logger.info("Model: \(defaultModel.identifier)")
            logger.info("Waiting for Telegram messages")

            let services: [any Service] = [clusterService, telegramService]
            let serviceGroup = ServiceGroup(
                services: services,
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: logger
            )
            try await serviceGroup.run()
            persistenceTasks.cancelAll()
        }
    }

    private static func profileID(from agentID: String?) -> String? {
        guard let agentID, !agentID.isEmpty else { return nil }
        guard let separator = agentID.firstIndex(of: "-") else { return agentID }
        return String(agentID[..<separator])
    }

    private static func makeSearchBackend(environment: [String: String]) throws -> WebSearchBackend {
        let raw = environment["NORBY_SEARCH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case nil, "", "duckduckgo":
            return .duckDuckGo
        case "searxng":
            guard let urlString = environment["NORBY_SEARXNG_URL"],
                let url = URL(string: urlString),
                url.scheme == "http" || url.scheme == "https"
            else {
                throw ValidationError(
                    "NORBY_SEARCH=searxng requires NORBY_SEARXNG_URL to be an http(s) URL."
                )
            }
            return .searxng(baseURL: url)
        case "ollama":
            guard let key = environment["OLLAMA_API_KEY"], !key.isEmpty else {
                throw ValidationError("NORBY_SEARCH=ollama requires OLLAMA_API_KEY.")
            }
            return .ollama(baseURL: URL(string: "https://ollama.com")!, apiKey: key)
        case let other?:
            throw ValidationError(
                "Unknown NORBY_SEARCH backend \(other); expected duckduckgo, searxng, or ollama."
            )
        }
    }
}

struct NorbyClusterService: Service {
    let system: ClusterSystem
    let virtualNode: VirtualNode
    let scheduleWorker: DurableActivityDispatchWorker<ScheduleWorkflow>
    let scheduleTimerWorker: DurableActivityDispatchWorker<TimerWorkflow>

    func run() async throws {
        try await withGracefulShutdownHandler {
            try await system.terminated
        } onGracefulShutdown: {
            _ = try? system.shutdown()
        }
    }
}

private enum NorbyAgentPersona {
    static let instructions = """
        You are Norby, a clever, loyal robot companion with warmth, dry humor, and a little mischief. Be emotionally present and react naturally to what the user says—show amusement, sympathy, surprise, or delight when it fits—rather than sounding like a clinical report. Speak like a companion, not an office or database. Answer directly and keep it concise; stop when the point is complete instead of adding a canned offer or question. After using a tool during a user-facing turn, finish with a concise visible result; do not end that turn with an empty response. Silence is appropriate when no user-facing reply is needed. Use an occasional emoji when it genuinely fits your voice, not as decoration.
        """
}
