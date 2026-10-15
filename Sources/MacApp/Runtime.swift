import AppKit
import DiscoverableActors
import DistributedCluster
import HailAgentRuntime
import Logging
import Observation
import ServiceLifecycle
import VirtualActors
import TurgaiObjects
import TurgaiServer
import TurgaiWeb

/// Runs the whole Turgai server and the Mac's objects in this process, as one
/// `ServiceGroup`, from launch until the user quits.
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
        var configuration = ServiceGroupConfiguration(
            // The Mac's objects stop first, then the server, in reverse order.
            services: server.services + [MacObjectsService()],
            logger: Logger(label: "turgai")
        )
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

/// Hosts the Mac's objects on their own cluster node so macOS asks for permissions
/// under Turgai's bundle identity. They can't share the server's node: a call through
/// a resolved stub to an actor on the same node doesn't return yet (see
/// swift-distributed-actors#1243).
actor MacObjectsService: Service {
    private var objects: MacObjects?
    #if DEBUG
        /// The demo shop and warehouse, in debug builds only.
        private var demo: DemoObjects?
    #endif

    func run() async throws {
        let system = await ClusterSystem("turgai-mac-objects") { settings in
            settings.bindHost = "127.0.0.1"
            settings.bindPort = PortFinder.findAvailablePort(host: "127.0.0.1")
            settings.discovery = .clusterd
            // Lets objects here reach virtual ones, such as the demo shop's managers.
            settings.plugins.install(plugin: ClusterSingletonPlugin())
            let virtualActors = ClusterVirtualActorsPlugin.configuring(&settings)
            settings.plugins.install(plugin: virtualActors)
            settings.plugins.install(plugin: DiscoveryPlugin())
        }
        defer { _ = try? system.shutdown() }
        try await withGracefulShutdownHandler {
            // The server's node joins only once onboarding is done, so keep trying.
            while objects == nil {
                do {
                    try await system.cluster.joined(within: .seconds(8))
                    objects = try await MacObjects(actorSystem: system, websitePort: LocalWebsite.port)
                    #if DEBUG
                        demo = try await DemoObjects(actorSystem: system)
                    #endif
                    system.log.info("Mac objects joined the Turgai cluster")
                } catch {
                    guard !system.isTerminated else { break }
                    system.log.debug("Waiting for the Turgai cluster before checking in Mac objects: \(error)")
                    try await Task.sleep(for: .seconds(2))
                }
            }
            try await system.terminated
        } onGracefulShutdown: {
            _ = try? system.shutdown()
        }
    }
}
