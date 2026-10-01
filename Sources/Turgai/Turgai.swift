import ArgumentParser
import ServiceLifecycle
import TurgaiServer
import TurgaiWeb

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@main
struct Turgai: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "turgai",
        abstract: "Run Turgai.",
        subcommands: [Serve.self],
        defaultSubcommand: Serve.self
    )
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the local Turgai server and Telegram bot."
    )

    @Option(name: .long, help: "Directory where Turgai stores its data. Defaults to ~/.turgai.")
    var directory: String?

    @Option(name: .long, help: "Local web server port.")
    var port: Int = 3333

    @Option(name: .long, help: "Public API authentication mode: local, api-key, or trusted-proxy.")
    var apiAuth: String = APIAuthMode.local.rawValue

    mutating func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard (1...65_535).contains(port) else {
            throw ValidationError("Port must be between 1 and 65535.")
        }
        guard let apiAuthMode = APIAuthMode(rawValue: apiAuth) else {
            throw ValidationError("API authentication must be local, api-key, or trusted-proxy.")
        }
        let apiKey = environment["TURGAI_API_KEY"]
        if apiAuthMode == .apiKey, apiKey?.isEmpty != false {
            throw ValidationError("TURGAI_API_KEY is required when --api-auth is api-key.")
        }
        let server = try TurgaiServer(
            directory: Self.dataDirectory(option: directory, fileManager: .default),
            port: port,
            api: APIConfiguration(authMode: apiAuthMode, apiKey: apiKey),
            environment: environment,
            workspaceRoot: FileManager.default.currentDirectoryPath
        )
        let serviceGroup = ServiceGroup(
            services: server.services,
            gracefulShutdownSignals: [.sigterm, .sigint]
        )
        try await serviceGroup.run()
    }

    private static func dataDirectory(
        option: String?,
        fileManager: FileManager
    ) -> URL {
        guard let option else { return TurgaiServer.defaultDirectory }
        let expandedPath = (option as NSString).expandingTildeInPath
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        return URL(fileURLWithPath: expandedPath, relativeTo: currentDirectory)
            .standardizedFileURL
    }
}
