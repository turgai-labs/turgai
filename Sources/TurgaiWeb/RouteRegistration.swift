import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import HummingbirdWebSocket
import NIOCore
import TurgaiApplication
import TurgaiDomain
import TurgaiHail
import TurgaiPeople
import TurgaiPersistence
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct TurgaiRouteDependencies: Sendable {
    let auth: TurgaiAuth
    let setup: TurgaiSetupStore
    let agentProfiles: TurgaiAgentProfileStore
    let agentCredentials: AgentCredentialStore
    let requestLimits: RequestLimitStore
    let channelSecrets: ChannelSecretStore
    /// Turgai's directory, where its own database is.
    let directory: URL
    let runtimeSnapshots: @Sendable (Membership) async -> [TurgaiAgentRuntimeSnapshot]
    let userToolRegistry: UserToolRegistry
    let webChatBridge: TurgaiWebChatBridge
    /// Who's the same human as whom.
    let linking: PersonLinking
    let apiConfiguration: APIConfiguration
}

extension TurgaiMainWebApp {
    public func registerRoutes(on router: Router<BasicWebSocketRequestContext>) {
        let dependencies = TurgaiRouteDependencies(
            auth: auth,
            setup: setup,
            agentProfiles: agentProfiles,
            agentCredentials: agentCredentials,
            requestLimits: requestLimits,
            channelSecrets: channelSecrets,
            directory: directory,
            runtimeSnapshots: runtimeSnapshots,
            userToolRegistry: UserToolRegistry(
                directory: directory.appendingPathComponent("tools", isDirectory: true)
            ),
            webChatBridge: webChatBridge,
            linking: linking,
            apiConfiguration: apiConfiguration
        )
        registerCoreRoutes(on: router, dependencies: dependencies)
        registerToolRoutes(on: router, dependencies: dependencies)
        registerAgentRoutes(on: router, dependencies: dependencies)
        registerChannelRoutes(on: router, dependencies: dependencies)
        registerPublicChatRoutes(on: router, dependencies: dependencies)
        registerAccountRoutes(on: router, dependencies: dependencies)
    }
}
