import Hummingbird
import HummingbirdWebSocket
import Logging
import ServiceLifecycle
import Synchronization
import TurgaiAgents
import TurgaiApplication
import TurgaiModels
import TurgaiPeople

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Setting Turgai up: its steps, signing in and out, and whether it's done. Turgai's one web server
/// answers with its routes until Turgai's own are handed to it; its run ends once setting up is
/// complete, and Turgai starts after it.
public struct TurgaiOnboardingWebApp: Service, Sendable {
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

    /// Its routes, which Turgai's web server answers with until Turgai's own are handed to it.
    public func router() -> Router<BasicWebSocketRequestContext> {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.addMiddleware { FileMiddleware(TurgaiWebAssets.publicRoot, searchForIndexHtml: false) }
        registerRoutes(on: router)
        return router
    }

    /// Waits until setting up is complete, or it's stopped first. Done before, it returns at once.
    public func run() async throws {
        guard !(await setup.isComplete) else { return }
        await withTaskCancellationOrGracefulShutdownHandler {
            await setup.waitUntilComplete()
        } onCancelOrGracefulShutdown: {
            Task { await setup.stopWaiting() }
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

/// Where Turgai's web server listens: on this machine only, unless it's told to listen on a network,
/// such as every one the machine is on. Whoever reaches it signs in all the same.
public struct WebHost: Hashable, Sendable, CustomStringConvertible {
    /// The address it listens on, as a host's own: `127.0.0.1`, or `0.0.0.0` for every network.
    public let name: String

    /// On `name`: none for what names no address.
    public init?(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" "), !trimmed.contains("/") else { return nil }
        self.name = trimmed
    }

    /// This machine only.
    public static let thisMachine = WebHost("127.0.0.1")!

    public var description: String { name }
}

/// Turgai's one web server, on one port for the whole run: it answers with setting up's routes, and
/// then with Turgai's, once they're handed to it. Nothing stops in between, so a page waiting for
/// Turgai to start simply gets it on its next request.
public final class TurgaiWebServer: Sendable {
    private let routes: Mutex<RouterResponder<BasicWebSocketRequestContext>>
    private let host: WebHost
    private let port: Int
    /// Told once it listens.
    private let listening: @Sendable () async -> Void

    /// Answering on `port`, where `host` says, with `router`'s routes; `listening` told once it
    /// listens.
    public init(
        serving router: Router<BasicWebSocketRequestContext>, on host: WebHost, port: Int,
        listening: @escaping @Sendable () async -> Void = {}
    ) {
        routes = Mutex(router.buildResponder())
        self.host = host
        self.port = port
        self.listening = listening
    }

    /// Its routes from now on: `router`'s, for requests and WebSockets alike.
    public func serve(_ router: Router<BasicWebSocketRequestContext>) {
        let responder = router.buildResponder()
        routes.withLock { $0 = responder }
    }

    /// It, run as a service.
    public var service: some Service {
        Application(
            responder: Current(server: self),
            server: .http1WebSocketUpgrade(webSocketRouter: Current(server: self)),
            configuration: .init(address: .hostname(host.name, port: port)),
            onServerRunning: { [listening] _ in await listening() }
        )
    }

    /// Whichever routes it answers with now.
    private struct Current: HTTPResponder, HTTPResponderBuilder {
        let server: TurgaiWebServer

        func respond(to request: Request, context: BasicWebSocketRequestContext) async throws -> Response {
            let routes = server.routes.withLock { $0 }
            return try await routes.respond(to: request, context: context)
        }

        func buildResponder() -> Current { self }
    }
}
