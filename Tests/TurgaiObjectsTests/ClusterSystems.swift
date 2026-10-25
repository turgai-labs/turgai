import DiscoverableActors
import DistributedCluster
import EventSourcing
import Foundation
import Hail
import VirtualActors

@testable import TurgaiApplication

/// A cluster node for a test, set up as Turgai runs one, journaled to `store`, and joined to
/// `other` when one is given. A node that hosts virtual actors has a `VirtualNode`; `installing`
/// adds what else it runs, such as Hail's agents. All it makes lives while `body` runs, and the
/// system shuts down after.
func withClusterSystem<Result>(
    _ name: String,
    store: MemoryEventStore,
    joining other: ClusterSystem? = nil,
    hostsVirtualActors: Bool,
    installing: @escaping @Sendable (inout ClusterSystemSettings) -> Void = { _ in },
    _ body: (ClusterSystem) async throws -> Result
) async throws -> Result {
    let system = await ClusterSystem(name) { settings in
        configure(&settings, store: store)
        installing(&settings)
    }
    let virtualNode = hostsVirtualActors ? await VirtualNode(actorSystem: system) : nil
    defer {
        _ = virtualNode
        _ = try? system.shutdown()
    }
    if let other {
        system.cluster.join(endpoint: other.cluster.endpoint)
        try await other.cluster.waitFor(system.cluster.node, .up, within: .seconds(10))
    }
    return try await body(system)
}

/// Settings for every node in these tests, journaled to `store`, all able to host the journal
/// and the virtual actors' router, which are cluster singletons and run on the leader: the first
/// node, as in Turgai.
private func configure(_ settings: inout ClusterSystemSettings, store: MemoryEventStore) {
    settings.bindHost = "127.0.0.1"
    settings.bindPort = PortFinder.findAvailablePort(host: "127.0.0.1")
    settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)
    settings.plugins.install(plugin: ClusterSingletonPlugin())
    let virtualActors = ClusterVirtualActorsPlugin.configuring(&settings)
    settings.plugins.install(plugin: virtualActors)
    settings.plugins.install(plugin: DiscoveryPlugin())
    settings.propagateCallChain()
    settings.plugins.install(plugin: ClusterJournalPlugin { _ in store })
}
