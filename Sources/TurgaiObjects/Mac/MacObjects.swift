import DistributedCluster

/// The Mac's own objects. Hold on to them: the cluster receptionist doesn't keep
/// actors alive, so they live as long as this value does.
public struct MacObjects: Sendable {
    public let website: Website

    /// Creates the objects, which check themselves in. The website serves on `websitePort`.
    public init(actorSystem system: ClusterSystem, websitePort: Int) async throws {
        self.website = try await Website(actorSystem: system, port: websitePort)
    }
}
