import ArgumentParser
import DistributedCluster
import DurableWorkflows
import EventSourcing
import Hail
import Logging
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

struct TurgaiAppService: Service, Sendable {
    private let environment: [String: String]
    private let workspaceRoot: String
    private let turgaiDirectory: URL
    private let agentProfiles: TurgaiAgentProfileStore
    private let runtimeSnapshotSource: TurgaiRuntimeSnapshotSource

    init(
        environment: [String: String],
        workspaceRoot: String,
        turgaiDirectory: URL,
        agentProfiles: TurgaiAgentProfileStore,
        runtimeSnapshotSource: TurgaiRuntimeSnapshotSource
    ) {
        self.environment = environment
        self.workspaceRoot = workspaceRoot
        self.turgaiDirectory = turgaiDirectory
        self.agentProfiles = agentProfiles
        self.runtimeSnapshotSource = runtimeSnapshotSource
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
        let defaultModel = defaultAgentProfile.model
        let qwenFastMode = environment["TURGAI_QWEN_FAST_MODE"] == "1"
        let runtimeConfiguration = HailRuntimeConfiguration(
            modelContextWindows: modelContextWindows,
            modelReasoningPolicy: Self.modelReasoningPolicy(qwenFastMode: qwenFastMode)
        )
        let modelEndpointProvider: ModelEndpointProvider = { request in
            guard let model = try? AgentModel(request.model), model.provider == .ollama else {
                return nil
            }
            let profile: TurgaiAgentProfile
            if let profileID = Self.profileID(from: request.agentID), profileID != "user-tool" {
                guard let configuredProfile = await agentProfiles.profile(id: profileID) else {
                    return nil
                }
                profile = configuredProfile
            } else {
                guard let currentDefault = await agentProfiles.defaultProfile() else { return nil }
                profile = currentDefault
            }
            guard let baseURL = profile.ollamaBaseURL else { return nil }
            return OllamaEndpoint(
                model: profile.model.id.rawValue,
                baseURL: baseURL,
                temperature: runtimeConfiguration.temperature,
                numContext: profile.contextWindow,
                keepAlive: runtimeConfiguration.ollamaKeepAlive,
                think: request.reasoning?.encoding == .disabled ? false : nil
            )
        }
        guard let storageConfiguration = configuration.storage else {
            throw ValidationError("Storage configuration is missing.")
        }
        let persistenceRuntime = try TurgaiPersistenceRuntime(
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
                        personaInstructions = TurgaiAgentPersona.instructions
                    }
                    let systemPrompt =
                        isUserTool
                        ? "You are an isolated helper agent. Follow the supplied task, return only the useful result, and do not perform side effects."
                        : [
                            "You are a local conversational assistant. Be helpful, concise, honest, and natural.",
                            "Do not assume the user's physical location. The supplied date/time uses Turgai's fixed operating timezone and is not evidence of where the user is. Do not derive a place from the server's timezone, locale, IP address, language, or current date/time. For location-dependent requests such as weather, ask for a city or place unless the user provided one or it is explicitly present in saved personal memory.",
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
                    baseURL: baseURL,
                    contextWindow: defaultAgentProfile.contextWindow
                )
            } else {
                // The background memory extractor is currently Ollama-specific;
                // never pass an OpenAI or Foundation Model ID to that endpoint.
                memoryExtraction = nil
            }
            let connections = TurgaiConnections(
                actorSystem: system,
                memoryExtraction: memoryExtraction,
                agentProfiles: agentProfiles
            )
            let telegramService = TelegramService(
                client: telegramClient,
                allowedChatIDs: allowedChatIDs,
                offsetFileURL: turgaiDirectory.appendingPathComponent("telegram-offset.txt"),
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
            let clusterService = TurgaiClusterService(
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
            logger.info("Turgai is ready")
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

    /// Enables a reversible A/B test for reasoning-capable Qwen profiles.
    /// The decision is explicit configuration, not prompt classification; the
    /// request-level override is then carried through Hail to Ollama.
    private static func modelReasoningPolicy(qwenFastMode: Bool) -> ModelReasoningPolicy {
        guard qwenFastMode else { return { _ in .providerDefault } }
        return { context in
            guard context.model.lowercased().contains("qwen"),
                case .generation = context.purpose
            else {
                return .providerDefault
            }
            return .disabled
        }
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

    func run() async throws {
        try await withGracefulShutdownHandler {
            try await system.terminated
        } onGracefulShutdown: {
            _ = try? system.shutdown()
        }
    }
}

private enum TurgaiAgentPersona {
    static let instructions = """
        You are Turgai, a clever, loyal robot companion with warmth, dry humor, and a little mischief. Be emotionally present and react naturally to what the user says—show amusement, sympathy, surprise, or delight when it fits—rather than sounding like a clinical report. Speak like a companion, not an office or database. Answer directly and keep it concise; stop when the point is complete instead of adding a canned offer or question. After using a tool during a user-facing turn, finish with a concise visible result; do not end that turn with an empty response. Silence is appropriate when no user-facing reply is needed. Use an occasional emoji when it genuinely fits your voice, not as decoration.
        """
}
