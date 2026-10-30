import DistributedCluster
import Logging
import ServiceLifecycle

/// Runs the cluster daemon that nodes find each other through, logging at `logLevel`.
struct Daemon: Service {
    let logLevel: Logger.Level

    func run() async throws {
        let logLevel = logLevel
        let system = await ClusterSystem.startClusterDaemon { $0.logging.logLevel = logLevel }.system
        // Stopped by a graceful shutdown, or when the group is cancelled: waiting for the system
        // to end doesn't end on cancellation.
        try await withTaskCancellationOrGracefulShutdownHandler {
            try await system.terminated
        } onCancelOrGracefulShutdown: {
            _ = try? system.shutdown()
        }
    }
}
