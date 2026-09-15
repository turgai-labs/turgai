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
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@main
struct Norby: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "Norby",
        abstract: "Run Norby as a Telegram bot."
    )

    @Option(help: "Telegram bot token. Defaults to NORBY_TELEGRAM_BOT_TOKEN.")
    var telegramBotToken: String?

    @Option(
        help:
            "Comma-separated Telegram chat IDs allowed to talk to the bot. Defaults to NORBY_TELEGRAM_CHAT_IDS; empty means everyone."
    )
    var telegramChatIDs: String?

    @Option(help: "Model identifier. Defaults to NORBY_MODEL or ollama/qwen3.5:9b")
    var model: String?

    @Option(help: "Ollama base URL. Defaults to OLLAMA_BASE_URL or http://127.0.0.1:11434.")
    var ollamaBaseURL: String?

    @Option(help: "Model context window and Ollama num_ctx. Defaults to NORBY_CONTEXT_WINDOW or 16384.")
    var contextWindow: Int?

    @Option(help: "Workspace root; journals and state live in <root>/.norby. Defaults to the current directory.")
    var workspace: String?

    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let workspaceRoot = workspace ?? FileManager.default.currentDirectoryPath
        let norbyDirectory = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(".norby", isDirectory: true)
        let auth = try NorbyAuth(
            directory: norbyDirectory.appendingPathComponent("auth", isDirectory: true)
        )
        if !(await auth.hasAdmin()) {
            print("Norby first-run setup token: \(await auth.setupToken)")
            print("Use it to create the first administrator in the dashboard.")
        }

        guard
            let telegramBotToken = firstNonEmpty(
                telegramBotToken,
                environment["NORBY_TELEGRAM_BOT_TOKEN"]
            )
        else {
            throw ValidationError(
                "Telegram bot token is required. Pass --telegram-bot-token or set NORBY_TELEGRAM_BOT_TOKEN."
            )
        }

        // Share one Bot API client between transport and dynamic tool
        // approvals so callback handling and approval messages use the same
        // dependency boundary.
        let telegramClient = try TelegramAPIClient.live(token: telegramBotToken)
        let telegramApproval = TelegramToolApproval(client: telegramClient)

        let userToolsDirectory =
            norbyDirectory
            .appendingPathComponent("tools", isDirectory: true)
        let wasmRunnerURL = WasmRunnerLocator.executableURL(environment: environment)
        let persistenceClient = try FilePersistenceClient(directory: norbyDirectory)
        let conversationJournals = try await ConversationJournalReader(
            client: persistenceClient
        ).conversationJournals()
        let persistedConversationIDs = conversationJournals.map(\.conversationID)

        let modelIdentifier =
            firstNonEmpty(model, environment["NORBY_MODEL"])
            ?? "ollama/qwen3.5:9b"
        let ollamaURLString =
            firstNonEmpty(ollamaBaseURL, environment["OLLAMA_BASE_URL"])
            ?? "http://127.0.0.1:11434"
        guard let ollamaURL = URL(string: ollamaURLString) else {
            throw ValidationError("Invalid Ollama base URL: \(ollamaURLString)")
        }
        let configuredContextWindow = try Self.resolveContextWindow(
            contextWindow,
            environment: environment
        )
        let runtimeConfiguration = HailRuntimeConfiguration(
            modelIdentifier: modelIdentifier,
            ollamaBaseURL: ollamaURL,
            contextWindow: configuredContextWindow
        )
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
            workspaceRoot: workspaceRoot,
            definitionProvider: { spawnConfig in
                let role = spawnConfig.agentID.role.rawValue
                guard role == "conversation" || role == "user-tool" else {
                    return nil
                }

                let isUserTool = role == "user-tool"
                return try AgentDefinition(
                    role: spawnConfig.agentID.role,
                    behavior: .init(
                        systemPrompt: isUserTool
                            ? "You are an isolated helper agent. Follow the supplied task, return only the useful result, and do not perform side effects."
                            : "You are a local conversational assistant. Be helpful, concise, honest, and natural."
                                + "\n\n" + MemoryRetrieval.capabilityInstruction,
                        model: modelIdentifier,
                        execution: isUserTool
                            ? AgentExecutionPolicy(
                                sandbox: .readOnly,
                                approvalPolicy: .onRequest
                            )
                            : .autonomousWorkspace
                    ),
                    persona: isUserTool ? nil : NorbyAgentProfile.persona
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
                    approval: telegramApproval,
                    actorSystem: actorSystem,
                    includeConversationTools: context.agentID.role.rawValue == "conversation"
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
            },
        )
        let eventStore = FileEventStore(client: persistenceClient)
        let snapshotStore = FileSnapshotStore(client: persistenceClient)
        let journalPlugin = ClusterJournalPlugin(
            factory: { _ in eventStore },
            snapshotFactory: { _ in snapshotStore }
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
        let chatIDList = telegramChatIDs ?? environment["NORBY_TELEGRAM_CHAT_IDS"]
        let allowedChatIDs = Self.parseChatIDs(chatIDList)
        let extractionModel = try? AgentModel(runtimeConfiguration.modelIdentifier).id.rawValue
        let connections = NorbyConnections(
            actorSystem: system,
            ollamaBaseURL: runtimeConfiguration.ollamaBaseURL,
            memoryModel: extractionModel
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
        logger.info("Model: \(runtimeConfiguration.modelIdentifier)")
        logger.info("Waiting for Telegram messages")

        let serviceGroup = ServiceGroup(
            services: [clusterService, telegramService],
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: logger
        )
        try await serviceGroup.run()
    }

    private static func parseChatIDs(_ value: String?) -> Set<Int64> {
        Set(
            value?
                .split(separator: ",")
                .compactMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                ?? []
        )
    }

    private static func resolveContextWindow(
        _ option: Int?,
        environment: [String: String]
    ) throws -> Int {
        let value: Int
        if let option {
            value = option
        } else if let raw = environment["NORBY_CONTEXT_WINDOW"] {
            guard let parsed = Int(raw) else {
                throw ValidationError(
                    "NORBY_CONTEXT_WINDOW must be a positive integer, got \(raw)."
                )
            }
            value = parsed
        } else {
            value = 16_384
        }

        guard value > 0 else {
            throw ValidationError("Context window must be a positive integer, got \(value).")
        }
        return value
    }

    /// Picks the web search backend from the environment. The model never
    /// sees this choice; it is infrastructure configuration, made once at
    /// startup and failing loudly on misconfiguration.
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

private struct NorbyClusterService: Service {
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

private enum NorbyAgentProfile {
    static let persona = AgentPersona(
        displayName: "Norby",
        instructions: """
            You are Norby, a clever, loyal robot companion with warmth, dry humor, and a little mischief. Be emotionally present and react naturally to what the user says—show amusement, sympathy, surprise, or delight when it fits—rather than sounding like a clinical report. Speak like a companion, not an office or database. Answer directly and keep it concise; stop when the point is complete instead of adding a canned offer or question. After using a tool during a user-facing turn, finish with a concise visible result; do not end that turn with an empty response. Silence is appropriate when no user-facing reply is needed. Use an occasional emoji when it genuinely fits your voice, not as decoration.
            """
    )
}

private func firstNonEmpty(_ values: String?...) -> String? {
    values.lazy
        .compactMap { $0 }
        .first { !$0.isEmpty }
}
