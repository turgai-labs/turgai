import Hummingbird
import HummingbirdWebSocket
import Logging
import ServiceLifecycle
import TurgaiAgents
import TurgaiApplication
import TurgaiConversations
import TurgaiObjects
import TurgaiPeople
import TurgaiPersistence
import TurgaiSpaces
import TurgaiWeb

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The whole local Turgai server: the cluster daemon, setting up's web app until it's done, then
/// the runtime with the main web app on it.
/// The `turgai` command and the Mac app both run its services in a `ServiceGroup`.
public struct TurgaiServer: Sendable {
    /// Run in this order: `ServiceGroup` shuts services down in reverse, so the runtime, whose web
    /// app stops first, stops before the daemon, and the database closes last.
    public let services: [any Service]

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
        logLevel: Logger.Level,
        api: APIConfiguration,
        environment: [String: String],
        workspaceRoot: String
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
        let agentCredentials = AgentCredentialStore(storage: try await .live(in: persistence, key: secretKey))
        let requestLimits = try await RequestLimitStore(storage: try await .live(in: persistence))
        let linking = PersonLinking(storage: try await .live(in: persistence))
        let channelSecrets = ChannelSecretStore(storage: try await .live(in: persistence, key: secretKey))
        let setup = try TurgaiSetupStore(directory: directory)
        let onboardingWebApp = TurgaiOnboardingWebApp(
            auth: auth,
            directory: directory,
            agentCredentials: agentCredentials,
            setup: setup
        )
        let appService = TurgaiAppService(
            environment: environment,
            workspaceRoot: workspaceRoot,
            turgaiDirectory: directory,
            persistence: persistence,
            agentCredentials: agentCredentials,
            requestLimits: requestLimits,
            channelSecrets: channelSecrets,
            linking: linking,
            auth: auth,
            spaceDirectory: try await .live(in: persistence),
            conversationDirectory: try await .live(in: persistence),
            memoryNotices: try await .live(named: "memory-notices", in: persistence),
            connectionPolicy: try await .live(named: "connection-policy", in: persistence),
            setup: setup,
            port: port,
            api: api,
            logLevel: logLevel
        )
        let runtimeService = TurgaiRuntimeService(
            onboarding: onboardingWebApp,
            application: appService,
            port: port
        )
        self.services = [Database(persistence: persistence), Daemon(logLevel: logLevel), runtimeService]
    }

    /// Where Turgai keeps its data unless told otherwise: `~/.turgai`.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".turgai", isDirectory: true)
    }
}

/// Setting up, on its own web server until it's done; then the runtime, which serves the main web
/// app on the same port once its cluster runs.
private struct TurgaiRuntimeService: Service, Sendable {
    let onboarding: TurgaiOnboardingWebApp
    let application: TurgaiAppService
    let port: Int

    func run() async throws {
        try await onboarding.run(port: port, logger: Logger(label: "turgai.onboarding"))
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
