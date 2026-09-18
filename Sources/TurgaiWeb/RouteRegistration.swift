import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import HummingbirdWebSocket
import NIOCore
import TurgaiApplication
import TurgaiHail
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
    let defaultFileDirectory: URL
    let runtimeSnapshots: @Sendable () async -> [TurgaiAgentRuntimeSnapshot]
    let userToolRegistry: UserToolRegistry
    let webChatBridge: TurgaiWebChatBridge
}

extension TurgaiMainWebApp {
    public func registerRoutes(on router: Router<BasicWebSocketRequestContext>) {
        let dependencies = TurgaiRouteDependencies(
            auth: auth,
            setup: setup,
            agentProfiles: agentProfiles,
            defaultFileDirectory: directory,
            runtimeSnapshots: runtimeSnapshots,
            userToolRegistry: UserToolRegistry(
                directory: directory.appendingPathComponent("tools", isDirectory: true)
            ),
            webChatBridge: webChatBridge
        )
        registerCoreRoutes(on: router, dependencies: dependencies)
        registerToolRoutes(on: router, dependencies: dependencies)
        registerAgentRoutes(on: router, dependencies: dependencies)
        registerAccountRoutes(on: router, dependencies: dependencies)
    }
}
