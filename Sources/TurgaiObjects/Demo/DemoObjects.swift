import DistributedCluster

/// The pretend shop and warehouse, for trying out objects and their events. Hold on to
/// them: the cluster receptionist doesn't keep actors alive.
public struct DemoObjects: Sendable {
    public let shop: Shop
    public let warehouse: Warehouse

    /// Creates the objects, which check themselves in.
    public init(actorSystem system: ClusterSystem) async throws {
        self.shop = try await Shop(actorSystem: system)
        self.warehouse = try await Warehouse(actorSystem: system)
    }
}
