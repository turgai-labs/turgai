import DistributedCluster
import Logging
import ServiceLifecycle

/// Runs the cluster daemon that nodes find each other through, logging at `logLevel`.
struct Daemon: Service {
    let logLevel: Logger.Level

    func run() async throws {
        let logLevel = logLevel
        let system = await ClusterSystem.startClusterDaemon { $0.logging.logLevel = logLevel }.system
        try await withGracefulShutdownHandler {
            try await system.terminated
        } onGracefulShutdown: {
            _ = try? system.shutdown()
        }
    }
}
