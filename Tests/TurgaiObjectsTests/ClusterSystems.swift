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
    let result: Result
    do {
        if let other {
            system.cluster.join(endpoint: other.cluster.endpoint)
            try await other.cluster.waitFor(system.cluster.node, .up, within: .seconds(10))
        }
        result = try await body(system)
    } catch {
        await shutDown(system, keeping: virtualNode)
        throw error
    }
    await shutDown(system, keeping: virtualNode)
    return result
}

/// Shuts `system` down on a thread of its own, holding `virtualNode` until it has: its shutdown
/// waits on its event loops and on work of its own, so on one of Swift's concurrency threads it
/// holds that thread, and enough tests ending at once would hold every one, with none left to
/// finish any of them.
private func shutDown(_ system: ClusterSystem, keeping virtualNode: VirtualNode?) async {
    await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
        Thread.detachNewThread {
            withExtendedLifetime(virtualNode) { _ = try? system.shutdown() }
            finished.resume()
        }
    }
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
    settings.checkObjectAccess()
    settings.plugins.install(plugin: ClusterJournalPlugin { _ in store })
}
