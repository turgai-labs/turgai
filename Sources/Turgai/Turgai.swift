import ArgumentParser
import Hummingbird
import TurgaiApplication
import TurgaiWeb

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@main
struct Turgai: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "Turgai",
        abstract: "Run Turgai as a Telegram bot."
    )

    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let workspaceRoot = FileManager.default.currentDirectoryPath
        let turgaiDirectory = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(".turgai", isDirectory: true)
        let auth = try TurgaiAuth(
            directory: turgaiDirectory.appendingPathComponent("auth", isDirectory: true)
        )

        let configuration = try TurgaiWebConfiguration.load(directory: turgaiDirectory)
        let agentProfiles = try TurgaiAgentProfileStore(
            directory: turgaiDirectory.appendingPathComponent("agents", isDirectory: true)
        )
        let runtimeSnapshotSource = TurgaiRuntimeSnapshotSource()
        let onboardingWebApp = try TurgaiOnboardingWebApp(
            auth: auth,
            directory: turgaiDirectory,
            agentProfiles: agentProfiles
        )
        let mainWebApp = try TurgaiMainWebApp(
            auth: auth,
            directory: turgaiDirectory,
            agentProfiles: agentProfiles,
            runtimeSnapshots: { await runtimeSnapshotSource.snapshots() }
        )
        let router = Router<BasicRequestContext>()
        router.addMiddleware {
            FileMiddleware(TurgaiWebAssets.publicRoot, searchForIndexHtml: false)
        }
        onboardingWebApp.registerRoutes(on: router)
        mainWebApp.registerRoutes(on: router)
        let application = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 3333))
        )
        let appService = TurgaiAppService(
            environment: environment,
            workspaceRoot: workspaceRoot,
            turgaiDirectory: turgaiDirectory,
            agentProfiles: agentProfiles,
            runtimeSnapshotSource: runtimeSnapshotSource
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await application.run()
            }
            group.addTask {
                if !configuration.isReady {
                    try await onboardingWebApp.run()
                }
                try await appService.run()
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }
}
