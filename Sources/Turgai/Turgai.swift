import ArgumentParser
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
        let webApp = try TurgaiWebApp(
            auth: auth,
            directory: turgaiDirectory,
            agentProfiles: agentProfiles,
            runtimeSnapshots: { await runtimeSnapshotSource.snapshots() }
        )
        let onboardingService = TurgaiOnboardingService(webApp: webApp)
        let appService = TurgaiAppService(
            environment: environment,
            workspaceRoot: workspaceRoot,
            turgaiDirectory: turgaiDirectory,
            agentProfiles: agentProfiles,
            runtimeSnapshotSource: runtimeSnapshotSource
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await webApp.run()
            }
            group.addTask {
                if !configuration.isReady {
                    try await onboardingService.run()
                }
                try await appService.run()
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }
}
