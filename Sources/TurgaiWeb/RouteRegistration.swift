import DistributedCluster
import Elementary
import EventSourcing
import Hail
import Hummingbird
import HummingbirdElementary
import HummingbirdWebSocket
import NIOCore
import TurgaiAgents
import TurgaiApplication
import TurgaiDomain
import TurgaiHail
import TurgaiObjects
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
    let agentCredentials: AgentCredentialStore
    let requestLimits: RequestLimitStore
    let channelSecrets: ChannelSecretStore
    /// Turgai's directory, where its own database is.
    let directory: URL
    let userToolRegistry: UserToolRegistry
    /// The cluster Turgai runs on, which every actor the routes call is reached through.
    let system: ClusterSystem
    /// Where the agents keep what they did, read for their past turns.
    let journal: any EventStore
    /// Who's the same human as whom.
    let linking: PersonLinking
    let apiConfiguration: APIConfiguration
}

extension TurgaiMainWebApp {
    public func registerRoutes(on router: Router<BasicWebSocketRequestContext>) {
        let dependencies = TurgaiRouteDependencies(
            auth: auth,
            setup: setup,
            agentCredentials: agentCredentials,
            requestLimits: requestLimits,
            channelSecrets: channelSecrets,
            directory: directory,
            userToolRegistry: UserToolRegistry(
                directory: directory.appendingPathComponent("tools", isDirectory: true)
            ),
            system: system,
            journal: journal,
            linking: linking,
            apiConfiguration: apiConfiguration
        )
        registerCoreRoutes(on: router, dependencies: dependencies)
        registerToolRoutes(on: router, dependencies: dependencies)
        registerSpacePageRoutes(on: router, dependencies: dependencies)
        registerConnectionRoutes(on: router, dependencies: dependencies)
        registerPublicChatRoutes(on: router, dependencies: dependencies)
        registerAccountRoutes(on: router, dependencies: dependencies)
        registerWebsiteRoutes(on: router, dependencies: dependencies)
    }
}
