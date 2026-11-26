import AppKit
import Logging
import Observation
import ServiceLifecycle
import TurgaiClient
import TurgaiServer
import TurgaiWeb

/// Runs the whole Turgai server in this process, as one `ServiceGroup`, from launch until the
/// user quits.
@MainActor
@Observable
final class Runtime {
    enum Status: Equatable {
        case running
        case stopping
        case stopped(reason: String)
    }

    private(set) var status = Status.running
    @ObservationIgnored private var group: ServiceGroup?
    @ObservationIgnored private var run: Task<Void, Never>?

    /// Runs it, `listening` told once its web server listens.
    init(listening: @escaping @Sendable () async -> Void) {
        self.run = Task {
            let server: TurgaiServer
            do {
                server = try await TurgaiServer(
                    directory: TurgaiServer.defaultDirectory,
                    secretKey: try SecretKeychain.secretKey(),
                    host: .thisMachine,
                    port: ServerAddress.onThisMac.url.port ?? 3333,
                    logLevel: .info,
                    api: APIConfiguration(),
                    environment: ProcessInfo.processInfo.environment,
                    workspaceRoot: FileManager.default.homeDirectoryForCurrentUser.path,
                    listening: listening
                )
            } catch {
                self.stopped(reason: String(describing: error))
                return
            }
            var configuration = ServiceGroupConfiguration(services: server.services, logger: Logger(label: "turgai"))
            configuration.maximumGracefulShutdownDuration = .seconds(10)
            configuration.maximumCancellationDuration = .seconds(5)
            let group = ServiceGroup(configuration: configuration)
            self.group = group
            do {
                try await group.run()
                self.stopped(reason: "the server exited")
            } catch {
                self.stopped(reason: String(describing: error))
            }
        }
    }

    /// Stops every service, then the app.
    func quit() {
        guard let group, let run, status == .running else {
            NSApplication.shared.terminate(nil)
            return
        }
        status = .stopping
        Task {
            await group.triggerGracefulShutdown()
            await run.value
            NSApplication.shared.terminate(nil)
        }
    }

    private func stopped(reason: String) {
        guard status == .running else { return }
        status = .stopped(reason: reason)
    }
}
