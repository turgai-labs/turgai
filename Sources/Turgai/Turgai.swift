import ArgumentParser
import Hummingbird
import HummingbirdWebSocket
import ServiceLifecycle
import TurgaiApplication
import TurgaiPersistence
import TurgaiWeb

public typealias OutboundDelivery = TurgaiApplication.OutboundDelivery

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@main
struct Turgai: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "turgai",
        abstract: "Run Turgai.",
        subcommands: [Serve.self],
        defaultSubcommand: Serve.self
    )
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the local Turgai server and Telegram bot."
    )

    @Option(name: .long, help: "Directory where Turgai stores its data. Defaults to ~/.turgai.")
    var directory: String?

    @Option(name: .long, help: "Local web server port.")
    var port: Int = 3333

    @Option(name: .long, help: "Public API authentication mode: local, api-key, or trusted-proxy.")
    var apiAuth: String = APIAuthMode.local.rawValue

    mutating func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let workspaceRoot = FileManager.default.currentDirectoryPath
        guard (1...65_535).contains(port) else {
            throw ValidationError("Port must be between 1 and 65535.")
        }
        guard let apiAuthMode = APIAuthMode(rawValue: apiAuth) else {
            throw ValidationError("API authentication must be local, api-key, or trusted-proxy.")
        }
        let apiKey = environment["TURGAI_API_KEY"]
        if apiAuthMode == .apiKey, apiKey?.isEmpty != false {
            throw ValidationError("TURGAI_API_KEY is required when --api-auth is api-key.")
        }
        let turgaiDirectory = Self.dataDirectory(
            option: directory,
            fileManager: .default
        )
        let auth = try TurgaiAuth(
            directory: turgaiDirectory.appendingPathComponent("auth", isDirectory: true)
        )

        let fileClient = try FileClient(directory: turgaiDirectory)
        let agentProfiles = try TurgaiAgentProfileStore(files: fileClient)
        let agentCredentials = AgentCredentialStore(files: fileClient)
        let channelSecrets = ChannelSecretStore(files: fileClient)
        let setup = try TurgaiSetupStore(directory: turgaiDirectory)
        let webChatBridge = TurgaiWebChatBridge()
        let runtimeSnapshotSource = TurgaiRuntimeSnapshotSource()
        let onboardingWebApp = try TurgaiOnboardingWebApp(
            auth: auth,
            directory: turgaiDirectory,
            agentProfiles: agentProfiles,
            agentCredentials: agentCredentials,
            setup: setup,
            channelSecrets: channelSecrets
        )
        let mainWebApp = try TurgaiMainWebApp(
            auth: auth,
            directory: turgaiDirectory,
            agentProfiles: agentProfiles,
            agentCredentials: agentCredentials,
            channelSecrets: channelSecrets,
            runtimeSnapshots: { await runtimeSnapshotSource.snapshots() },
            setup: setup,
            webChatBridge: webChatBridge,
            apiConfiguration: APIConfiguration(authMode: apiAuthMode, apiKey: apiKey)
        )
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.addMiddleware {
            FileMiddleware(TurgaiWebAssets.publicRoot, searchForIndexHtml: false)
        }
        onboardingWebApp.registerRoutes(on: router)
        mainWebApp.registerRoutes(on: router)
        let application = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("127.0.0.1", port: port))
        )
        let appService = TurgaiAppService(
            environment: environment,
            workspaceRoot: workspaceRoot,
            turgaiDirectory: turgaiDirectory,
            agentProfiles: agentProfiles,
            agentCredentials: agentCredentials,
            channelSecrets: channelSecrets,
            runtimeSnapshotSource: runtimeSnapshotSource,
            webChatBridge: webChatBridge
        )

        let runtimeService = TurgaiRuntimeService(
            onboarding: onboardingWebApp,
            application: appService
        )
        let serviceGroup = ServiceGroup(
            // ServiceLifecycle shuts services down in reverse order. Stop the
            // HTTP application first so no new request can reach the cluster
            // while the runtime is draining its connections and actors.
            services: [runtimeService, application],
            gracefulShutdownSignals: [.sigterm, .sigint]
        )
        try await serviceGroup.run()
    }

    private static func dataDirectory(
        option: String?,
        fileManager: FileManager
    ) -> URL {
        guard let option else {
            return fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".turgai", isDirectory: true)
        }
        let expandedPath = (option as NSString).expandingTildeInPath
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        return URL(fileURLWithPath: expandedPath, relativeTo: currentDirectory)
            .standardizedFileURL
    }
}

private struct TurgaiRuntimeService: Service, Sendable {
    let onboarding: TurgaiOnboardingWebApp
    let application: TurgaiAppService

    func run() async throws {
        try await onboarding.run()
        try await application.run()
    }
}
