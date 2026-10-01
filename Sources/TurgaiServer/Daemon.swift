import DistributedCluster
import ServiceLifecycle

/// Runs the cluster daemon that nodes find each other through.
struct Daemon: Service {
    func run() async throws {
        let system = await ClusterSystem.startClusterDaemon().system
        try await withGracefulShutdownHandler {
            try await system.terminated
        } onGracefulShutdown: {
            _ = try? system.shutdown()
        }
    }
}
