import Hummingbird
import HummingbirdWebSocket
import Logging
import ServiceLifecycle
import TurgaiAgents
import TurgaiApplication
import TurgaiModels
import TurgaiPeople

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Setting Turgai up, on its own web server: its steps, signing in and out, and whether it's
/// done. It serves until setting up is complete; Turgai's cluster, and its main web app, start
/// after it.
public struct TurgaiOnboardingWebApp: Sendable {
    let directory: URL
    let auth: TurgaiAuth
    let setup: TurgaiSetupStore
    let agentCredentials: AgentCredentialStore

    public init(
        auth: TurgaiAuth,
        directory: URL,
        agentCredentials: AgentCredentialStore,
        setup: TurgaiSetupStore
    ) {
        self.directory = directory
        self.auth = auth
        self.setup = setup
        self.agentCredentials = agentCredentials
    }

    /// Serves setting up on `port` until it's complete, or the server stops first: then its server
    /// has stopped, and the port is free again.
    public func run(port: Int, logger: Logger) async throws {
        guard !(await setup.isComplete) else { return }
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.addMiddleware { FileMiddleware(TurgaiWebAssets.publicRoot, searchForIndexHtml: false) }
        registerRoutes(on: router)
        let server = ServiceGroup(
            services: [TurgaiWebServer.application(router: router, port: port)], gracefulShutdownSignals: [],
            logger: logger)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.run() }
            await withTaskCancellationOrGracefulShutdownHandler {
                await setup.waitUntilComplete()
            } onCancelOrGracefulShutdown: {
                Task { await setup.stopWaiting() }
            }
            await server.triggerGracefulShutdown()
            try await group.waitForAll()
        }
    }

    func registerRoutes(on router: Router<BasicWebSocketRequestContext>) {
        router.get { _, _ in TurgaiWebSupport.redirect(to: "/onboarding") }
        // Not set up yet: a client such as the Mac app waits until Turgai itself answers.
        router.get("/api/v1/status") { _, _ in
            try TurgaiWebSupport.jsonResponse(TurgaiServerStatus(setup: .pending))
        }
        registerSigningInAndOut(on: router, auth: auth, setup: setup)
        registerOnboardingRoutes(on: router)
    }
}

/// Turgai's web servers: setting up's, then the main app's, each on the same port in turn.
public enum TurgaiWebServer {
    /// The server for `router` on `port`, on this machine only.
    public static func application(router: Router<BasicWebSocketRequestContext>, port: Int) -> some Service {
        Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("127.0.0.1", port: port))
        )
    }
}
