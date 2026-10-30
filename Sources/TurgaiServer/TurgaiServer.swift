import Hummingbird
import HummingbirdWebSocket
import Logging
import ServiceLifecycle
import TurgaiApplication
import TurgaiObjects
import TurgaiPersistence
import TurgaiWeb

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The whole local Turgai server: the cluster daemon, the runtime and the web app.
/// The `turgai` command and the Mac app both run its services in a `ServiceGroup`.
public struct TurgaiServer: Sendable {
    /// Run in this order: `ServiceGroup` shuts services down in reverse, so the HTTP
    /// application stops first and no new request reaches a draining cluster, and the database
    /// closes last.
    public let services: [any Service]
    /// The runtime's object catalog, available once its cluster is up.
    public let objects: TurgaiObjectCatalogSource

    /// Forgets every secret Turgai keeps in `directory`, and the key they were sealed with, to start
    /// over with another: tokens and API keys are entered again, and everyone signs in again.
    public static func forgetSecrets(in directory: URL) async throws {
        let persistence = try await TurgaiPersistence.open(in: directory)
        try await ChannelTokenStorage.forgetAll(in: persistence)
        try await AgentCredentialStorage.forgetAll(in: persistence)
        try await SessionSecretStorage.forgetAll(in: persistence)
        try await persistence.forgetKey()
        try await persistence.close()
    }

    /// - Parameter secretKey: the key the platform holds, which every secret Turgai keeps is
    ///   sealed with.
    public init(
        directory: URL,
        secretKey: SecretKey,
        port: Int,
        websitePort: WebsitePort,
        logLevel: Logger.Level,
        api: APIConfiguration,
        environment: [String: String],
        workspaceRoot: String,
        objects: TurgaiObjectCatalogSource = TurgaiObjectCatalogSource()
    ) async throws {
        // Turgai's database first, opened once: accounts, agents, limits, conversations, channels
        // and the journal are kept there, each in tables of its own.
        let persistence = try await TurgaiPersistence.open(in: directory)
        // Before any secret is opened: a key that isn't the database's stops Turgai here.
        try await persistence.check(secretKey)
        let auth = try await TurgaiAuth(
            accounts: try await .live(in: persistence),
            sessionSecret: try await .live(in: persistence, key: secretKey)
        )
        let agentProfiles = TurgaiAgentProfileStore(storage: try await .live(in: persistence))
        let agentCredentials = AgentCredentialStore(storage: try await .live(in: persistence, key: secretKey))
        let requestLimits = try await RequestLimitStore(storage: try await .live(in: persistence))
        let channelSecrets = ChannelSecretStore(storage: try await .live(in: persistence, key: secretKey))
        let setup = try TurgaiSetupStore(directory: directory)
        let webChatBridge = TurgaiWebChatBridge()
        let runtimeSnapshotSource = TurgaiRuntimeSnapshotSource()
        let onboardingWebApp = try TurgaiOnboardingWebApp(
            auth: auth,
            directory: directory,
            agentProfiles: agentProfiles,
            agentCredentials: agentCredentials,
            requestLimits: requestLimits,
            setup: setup,
            channelSecrets: channelSecrets
        )
        let mainWebApp = try TurgaiMainWebApp(
            auth: auth,
            directory: directory,
            agentProfiles: agentProfiles,
            agentCredentials: agentCredentials,
            requestLimits: requestLimits,
            channelSecrets: channelSecrets,
            runtimeSnapshots: { await runtimeSnapshotSource.snapshots(as: $0) },
            setup: setup,
            webChatBridge: webChatBridge,
            apiConfiguration: api
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
            turgaiDirectory: directory,
            persistence: persistence,
            agentProfiles: agentProfiles,
            agentCredentials: agentCredentials,
            requestLimits: requestLimits,
            channelSecrets: channelSecrets,
            conversations: try await .live(in: persistence),
            channels: try await .live(in: persistence),
            turgaiSpace: try await .turgai(in: persistence),
            runtimeSnapshotSource: runtimeSnapshotSource,
            objectCatalogSource: objects,
            webChatBridge: webChatBridge,
            websitePort: websitePort,
            logLevel: logLevel
        )
        let runtimeService = TurgaiRuntimeService(
            onboarding: onboardingWebApp,
            application: appService
        )
        self.services = [Database(persistence: persistence), Daemon(logLevel: logLevel), runtimeService, application]
        self.objects = objects
    }

    /// Where Turgai keeps its data unless told otherwise: `~/.turgai`.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".turgai", isDirectory: true)
    }
}

/// Hands out the runtime's object catalog, waiting until the runtime has started.
public actor TurgaiObjectCatalogSource {
    private var catalog: ObjectCatalog?
    private var waiters: [CheckedContinuation<ObjectCatalog, Never>] = []

    public init() {}

    func set(_ catalog: ObjectCatalog) {
        self.catalog = catalog
        for waiter in waiters { waiter.resume(returning: catalog) }
        waiters.removeAll()
    }

    public func catalog() async -> ObjectCatalog {
        if let catalog { return catalog }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private struct TurgaiRuntimeService: Service, Sendable {
    let onboarding: TurgaiOnboardingWebApp
    let application: TurgaiAppService

    func run() async throws {
        try await onboarding.run()
        // Onboarding also ends when the server stops before it's done: then nothing runs after it.
        guard !Task.isShuttingDownGracefully, !Task.isCancelled else { return }
        try await application.run()
    }
}

/// Turgai's database, closed once every service that uses it has stopped. It's the first
/// service, so the last one a graceful shutdown reaches.
private struct Database: Service {
    let persistence: TurgaiPersistence

    func run() async throws {
        // Ended by a graceful shutdown or by cancellation: either way, the database closes.
        try? await gracefulShutdown()
        try await persistence.close()
    }
}
