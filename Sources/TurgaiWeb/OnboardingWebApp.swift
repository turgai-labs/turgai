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
    private let channelSecrets: ChannelSecretStore

    public init(
        auth: TurgaiAuth,
        directory: URL,
        agentProfiles: TurgaiAgentProfileStore,
        setup: TurgaiSetupStore,
        channelSecrets: ChannelSecretStore
    ) throws {
        self.directory = directory
        self.auth = auth
        self.setup = setup
        self.agentProfiles = agentProfiles
        self.channelSecrets = channelSecrets
    }

    public func registerRoutes(on router: Router<BasicWebSocketRequestContext>) {
        let dependencies = TurgaiRouteDependencies(
            auth: auth,
            setup: setup,
            agentProfiles: agentProfiles,
            channelSecrets: channelSecrets,
            defaultFileDirectory: directory,
            runtimeSnapshots: { [] },
            userToolRegistry: UserToolRegistry(
                directory: directory.appendingPathComponent("tools", isDirectory: true)
            ),
            webChatBridge: TurgaiWebChatBridge(),
            apiConfiguration: .init()
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
