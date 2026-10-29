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
    /// application stops first and no new request reaches a draining cluster.
    public let services: [any Service]
    /// The runtime's object catalog, available once its cluster is up.
    public let objects: TurgaiObjectCatalogSource

    public init(
        directory: URL,
        port: Int,
        websitePort: WebsitePort,
        logLevel: Logger.Level,
        api: APIConfiguration,
        environment: [String: String],
        workspaceRoot: String
    ) throws {
        let auth = try TurgaiAuth(
            directory: directory.appendingPathComponent("auth", isDirectory: true)
        )
        let fileClient = try FileClient(directory: directory)
        let agentProfiles = try TurgaiAgentProfileStore(files: fileClient)
        let agentCredentials = AgentCredentialStore(files: fileClient)
        let requestLimits = try RequestLimitStore(files: fileClient)
        let channelSecrets = ChannelSecretStore(files: fileClient)
        let setup = try TurgaiSetupStore(directory: directory)
        let webChatBridge = TurgaiWebChatBridge()
        let runtimeSnapshotSource = TurgaiRuntimeSnapshotSource()
        let objects = TurgaiObjectCatalogSource()
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
            agentProfiles: agentProfiles,
            agentCredentials: agentCredentials,
            requestLimits: requestLimits,
            channelSecrets: channelSecrets,
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
        self.services = [Daemon(logLevel: logLevel), runtimeService, application]
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
        try await application.run()
    }
}
