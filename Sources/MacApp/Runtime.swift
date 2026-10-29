import AppKit
import Logging
import Observation
import ServiceLifecycle
import TurgaiObjects
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
    /// The live objects, for the objects window.
    let objects: ObjectsClient
    @ObservationIgnored private let group: ServiceGroup?
    @ObservationIgnored private var run: Task<Void, Never>?

    init() {
        let server: TurgaiServer
        do {
            server = try TurgaiServer(
                directory: TurgaiServer.defaultDirectory,
                port: LocalServer.baseURL.port ?? 3333,
                websitePort: WebsitePort(rawValue: LocalWebsite.port),
                logLevel: .info,
                api: APIConfiguration(),
                environment: ProcessInfo.processInfo.environment,
                workspaceRoot: FileManager.default.homeDirectoryForCurrentUser.path
            )
        } catch {
            self.status = .stopped(reason: String(describing: error))
            self.objects = .unavailable
            self.group = nil
            return
        }
        var configuration = ServiceGroupConfiguration(services: server.services, logger: Logger(label: "turgai"))
        configuration.maximumGracefulShutdownDuration = .seconds(10)
        configuration.maximumCancellationDuration = .seconds(5)
        let group = ServiceGroup(configuration: configuration)
        self.objects = .live(server.objects)
        self.group = group
        self.run = Task {
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
