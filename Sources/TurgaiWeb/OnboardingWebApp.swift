import Hummingbird
import HummingbirdWebSocket
import ServiceLifecycle
import TurgaiApplication

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct TurgaiOnboardingWebApp: Service, Sendable {
    private let directory: URL
    private let auth: TurgaiAuth
    private let setup: TurgaiSetupStore
    private let agentProfiles: TurgaiAgentProfileStore

    public init(
        auth: TurgaiAuth,
        directory: URL,
        agentProfiles: TurgaiAgentProfileStore,
        setup: TurgaiSetupStore
    ) throws {
        self.directory = directory
        self.auth = auth
        self.setup = setup
        self.agentProfiles = agentProfiles
    }

    public func registerRoutes(on router: Router<BasicWebSocketRequestContext>) {
        let dependencies = TurgaiRouteDependencies(
            auth: auth,
            setup: setup,
            agentProfiles: agentProfiles,
            defaultFileDirectory: directory,
            runtimeSnapshots: { [] },
            userToolRegistry: UserToolRegistry(
                directory: directory.appendingPathComponent("tools", isDirectory: true)
            ),
            webChatBridge: TurgaiWebChatBridge()
        )
        registerOnboardingRoutes(on: router, dependencies: dependencies)
    }

    public func run() async throws {
        await withTaskCancellationOrGracefulShutdownHandler {
            await setup.waitUntilComplete()
        } onCancelOrGracefulShutdown: {
            Task {
                await setup.stopWaiting()
            }
        }
    }
}
