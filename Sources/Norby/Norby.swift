import ArgumentParser
import DistributedCluster
import EventSourcing
import Foundation
import Hail
import Logging
import NorbyApplication
import NorbyDomain
import NorbyHail
import NorbyMemory
import NorbyPersistence
import ServiceLifecycle
import VirtualActors

@main
struct Norby: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "Norby",
        abstract: "Run Norby as a Telegram bot."
    )

    @Option(help: "Telegram bot token. Defaults to NORBY_TELEGRAM_BOT_TOKEN.")
    var telegramBotToken: String?

    @Option(help: "Comma-separated Telegram chat IDs allowed to talk to the bot. Defaults to NORBY_TELEGRAM_CHAT_IDS; empty means everyone.")
    var telegramChatIDs: String?

    @Option(help: "Model route. Defaults to NORBY_MODEL or ollama/qwen3.5:9b")
    var model: String?

    @Option(help: "Ollama base URL. Defaults to OLLAMA_BASE_URL or http://127.0.0.1:11434.")
    var ollamaBaseURL: String?

    @Option(help: "Model context window and Ollama num_ctx. Defaults to NORBY_CONTEXT_WINDOW or 16384.")
    var contextWindow: Int?

    @Option(help: "Workspace root; journals and state live in <root>/.norby. Defaults to the current directory.")
    var workspace: String?

    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let telegramBotToken = firstNonEmpty(
            telegramBotToken,
            environment["NORBY_TELEGRAM_BOT_TOKEN"]
        ) else {
            throw ValidationError(
                "Telegram bot token is required. Pass --telegram-bot-token or set NORBY_TELEGRAM_BOT_TOKEN."
            )
        }

        let workspaceRoot = workspace ?? FileManager.default.currentDirectoryPath
        let norbyDirectory = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(".norby", isDirectory: true)
        let persistenceClient = try FilePersistenceClient(directory: norbyDirectory)
        let conversationJournals = try await ConversationJournalReader(
            client: persistenceClient
        ).conversationJournals()
        let recoverableConversationIDs = ConversationRecovery()
            .recoverableConversationIDs(from: conversationJournals)

        let modelRoute = firstNonEmpty(model, environment["NORBY_MODEL"])
            ?? "ollama/qwen3.5:9b"
        let ollamaURLString = firstNonEmpty(ollamaBaseURL, environment["OLLAMA_BASE_URL"])
            ?? "http://127.0.0.1:11434"
        guard let ollamaURL = URL(string: ollamaURLString) else {
            throw ValidationError("Invalid Ollama base URL: \(ollamaURLString)")
        }
        let configuredContextWindow = try Self.resolveContextWindow(
            contextWindow,
            environment: environment
        )
        let runtimeConfiguration = HailRuntimeConfiguration(
            modelRoute: modelRoute,
            ollamaBaseURL: ollamaURL,
            contextWindow: configuredContextWindow
        )
        let attachmentResolver = AttachmentResolver()
        let runtimePlugin = try runtimeConfiguration.makeAgentRuntimePlugin(
            workspaceRoot: workspaceRoot,
            definitionProvider: { spawnConfig in
                guard spawnConfig.agentID.role.rawValue == "conversation" else {
                    return nil
                }

                return try AgentDefinition(
                    role: spawnConfig.agentID.role,
                    behavior: .init(
                        systemPrompt: "You are a local conversational assistant. Be helpful, concise, and honest about what you know.",
                        model: modelRoute
                    ),
                    limits: .init(),
                    persona: NorbyAgentProfile.persona
                )
            },
            turnToolsProvider: { context, actorSystem in
                let userID: NorbyDomain.UserID?
                let sourceMessage: (text: String, timestamp: Date)?
                if case .text(let sender, let text, let timestamp) = context.message {
                    userID = NorbyDomain.UserID(rawValue: sender)
                    sourceMessage = (text, timestamp)
                } else {
                    userID = nil
                    sourceMessage = nil
                }

                var tools: [any Tool] = [
                    WebSearchTool(),
                    FetchURLTool(),
                    WeatherTool(),
                    FetchAttachmentTool(resolver: attachmentResolver),
                ]
                if let userID, let sourceMessage {
                    let observationUUID = UUID(uuidString: context.inputID ?? "")
                        ?? UUID(uuidString: context.turnID.rawValue)
                        ?? UUID()
                    let observation = MemoryObservation(
                        id: ObservationID(rawValue: observationUUID),
                        sourceID: MemorySourceID(rawValue: observationUUID),
                        text: sourceMessage.text,
                        observedAt: sourceMessage.timestamp
                    )
                    tools.append(
                        MemoryTool(
                            actorSystem: actorSystem,
                            userID: userID,
                            observation: observation
                        )
                    )
                }
                return tools
            }
        )
        let eventStore = FileEventStore(client: persistenceClient)
        let snapshotStore = FileSnapshotStore(client: persistenceClient)
        let journalPlugin = ClusterJournalPlugin(
            factory: { _ in eventStore },
            snapshotFactory: { _ in snapshotStore }
        )
        let virtualActorsPlugin = ClusterVirtualActorsPlugin()

        let system = await ClusterSystem("norby") { settings in
            settings.bindHost = "127.0.0.1"
            settings.bindPort = PortFinder.findAvailablePort(host: "127.0.0.1")
            settings.discovery = nil
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)
            settings.plugins.install(plugin: ClusterSingletonPlugin())
            settings.plugins.install(plugin: virtualActorsPlugin)
            settings.plugins.install(plugin: journalPlugin)
            settings.plugins.install(plugin: runtimePlugin)
        }

        try await system.cluster.joined(endpoint: system.cluster.endpoint, within: .seconds(10))
        let virtualNode = await VirtualNode(actorSystem: system)
        let chatIDList = telegramChatIDs ?? environment["NORBY_TELEGRAM_CHAT_IDS"]
        let allowedChatIDs = Self.parseChatIDs(chatIDList)
        let connections = NorbyConnections(
            actorSystem: system,
            snapshotPolicy: runtimeConfiguration.snapshotPolicy
        )
        let telegramService = try TelegramService(
            token: telegramBotToken,
            allowedChatIDs: allowedChatIDs,
            offsetFileURL: norbyDirectory.appendingPathComponent("telegram-offset.txt"),
            connections: connections,
            attachmentResolver: attachmentResolver,
            logger: system.log,
            persistedConversationIDs: recoverableConversationIDs
        )
        let clusterService = NorbyClusterService(
            system: system,
            virtualNode: virtualNode
        )

        let logger = system.log
        logger.info("Telegram enabled")
        if !allowedChatIDs.isEmpty {
            logger.info("Telegram chat allow-list enabled")
        }
        logger.info("Norby is ready")
        logger.info("Workspace: \(workspaceRoot)")
        logger.info("Model: \(runtimeConfiguration.modelRoute)")
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
}

private struct NorbyClusterService: Service {
    let system: ClusterSystem
    let virtualNode: VirtualNode

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
            You are Norby, a clever, loyal robot companion with dry, understated humor. Be warm but restrained, attentive without being eager to please, and comfortable with silence. Speak like a companion, not an office or database. Answer directly, ask only when something is genuinely missing, and use emoji sparingly.
            """
    )
}

private func firstNonEmpty(_ values: String?...) -> String? {
    values.lazy
        .compactMap { $0 }
        .first { !$0.isEmpty }
}
