import ArgumentParser
import NorbyApplication
import TurgaiWeb

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@main
struct Norby: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "Norby",
        abstract: "Run Norby as a Telegram bot."
    )

    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let workspaceRoot = FileManager.default.currentDirectoryPath
        let norbyDirectory = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(".norby", isDirectory: true)
        let auth = try NorbyAuth(
            directory: norbyDirectory.appendingPathComponent("auth", isDirectory: true)
        )

        let configuration = try TurgaiWebConfiguration.load(directory: norbyDirectory)
        let agentProfiles = try NorbyAgentProfileStore(
            directory: norbyDirectory.appendingPathComponent("agents", isDirectory: true)
        )
        let runtimeSnapshotSource = NorbyRuntimeSnapshotSource()
        let webApp = try TurgaiWebApp(
            auth: auth,
            directory: norbyDirectory,
            agentProfiles: agentProfiles,
            runtimeSnapshots: { await runtimeSnapshotSource.snapshots() }
        )
        let onboardingService = TurgaiOnboardingService(webApp: webApp)
        let appService = NorbyAppService(
            environment: environment,
            workspaceRoot: workspaceRoot,
            norbyDirectory: norbyDirectory,
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
