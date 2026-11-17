import ArgumentParser
import Logging
import ServiceLifecycle
import TurgaiPersistence
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
        subcommands: [Serve.self, ForgetSecrets.self],
        defaultSubcommand: Serve.self
    )
}

/// Starts over with a new secret key: what was sealed with the old one can't be opened again.
struct ForgetSecrets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forget-secrets",
        abstract: "Forget every secret Turgai keeps, to start over with a new secret key.",
        discussion: "Telegram tokens and API keys are entered again, and everyone signs in again."
    )

    @Option(name: .long, help: "Directory where Turgai stores its data. Defaults to ~/.turgai.")
    var directory: String?

    mutating func run() async throws {
        let directory = Serve.dataDirectory(option: directory, fileManager: .default)
        try await TurgaiServer.forgetSecrets(in: directory)
        print("Forgot Turgai's secrets in \(directory.path). Its next start keeps them with the key it's given.")
    }
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

    @Option(name: .long, help: "What the log shows: trace, debug, info, notice, warning, error, or critical.")
    var logLevel: String = Logger.Level.info.rawValue

    mutating func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard (1...65_535).contains(port) else {
            throw ValidationError("Port must be between 1 and 65535.")
        }
        guard let apiAuthMode = APIAuthMode(rawValue: apiAuth) else {
            throw ValidationError("API authentication must be local, api-key, or trusted-proxy.")
        }
        guard let level = Logger.Level(rawValue: logLevel) else {
            throw ValidationError("The log level must be trace, debug, info, notice, warning, error, or critical.")
        }
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = level
            return handler
        }
        let apiKey = environment["TURGAI_API_KEY"]
        if apiAuthMode == .apiKey, apiKey?.isEmpty != false {
            throw ValidationError("TURGAI_API_KEY is required when --api-auth is api-key.")
        }
        let server = try await TurgaiServer(
            directory: Self.dataDirectory(option: directory, fileManager: .default),
            secretKey: try Self.secretKey(environment: environment),
            port: port,
            logLevel: level,
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

    /// The key Turgai's secrets are sealed with, from where it's run: under systemd, its
    /// `turgai-key` credential; otherwise `TURGAI_SECRET_KEY`. Both are 32 random bytes, base64.
    private static func secretKey(environment: [String: String]) throws -> SecretKey {
        if let credentials = environment["CREDENTIALS_DIRECTORY"] {
            let file = URL(fileURLWithPath: credentials).appendingPathComponent("turgai-key")
            guard let written = try? String(contentsOf: file, encoding: .utf8) else {
                throw ValidationError("Turgai runs under systemd but has no turgai-key credential.")
            }
            return try SecretKey(base64: written)
        }
        guard let written = environment["TURGAI_SECRET_KEY"] else {
            throw ValidationError(
                "TURGAI_SECRET_KEY is required: 32 random bytes, base64, such as `openssl rand -base64 32` makes.")
        }
        return try SecretKey(base64: written)
    }

    static func dataDirectory(
        option: String?,
        fileManager: FileManager
    ) -> URL {
        guard let option else { return TurgaiServer.defaultDirectory }
        // `~` is the home directory, as a shell reads it.
        let expandedPath =
            option == "~" || option.hasPrefix("~/")
            ? fileManager.homeDirectoryForCurrentUser.path + option.dropFirst() : option
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        return URL(fileURLWithPath: expandedPath, relativeTo: currentDirectory)
            .standardizedFileURL
    }
}
