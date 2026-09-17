import Hummingbird
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
        agentProfiles: TurgaiAgentProfileStore
    ) throws {
        self.directory = directory
        self.auth = auth
        self.setup = try TurgaiSetupStore(directory: directory)
        self.agentProfiles = agentProfiles
    }

    public func registerRoutes(on router: Router<BasicRequestContext>) {
        let dependencies = TurgaiRouteDependencies(
            auth: auth,
            setup: setup,
            agentProfiles: agentProfiles,
            defaultFileDirectory: directory,
            runtimeSnapshots: { [] },
            userToolRegistry: UserToolRegistry(
                directory: directory.appendingPathComponent("tools", isDirectory: true)
            )
        )
        registerOnboardingRoutes(on: router, dependencies: dependencies)
    }

    public func run() async throws {
        await setup.waitUntilComplete()
    }
}
