import DiscoverableActors
import DistributedCluster
import EventSourcing
import Foundation
import Hail
import RunningActors
import TurgaiCalls
import TurgaiDomain
import TurgaiSpaces
import VirtualActors

@testable import TurgaiApplication

/// A cluster node for a test, set up as Turgai runs one, journaled to `store`, and joined to
/// `other` when one is given. A node that hosts virtual actors has a `VirtualNode`; `installing`
/// adds what else it runs, such as Hail's agents. Whoever `people` are on behalf of is in their
/// space, as a platform would say: the tester decides for it, and everyone else is a member: the test's person, unless it names others. All
/// it makes lives while `body` runs, and the system shuts down after.
func withClusterSystem<Result>(
    _ name: String,
    store: MemoryEventStore,
    joining other: ClusterSystem? = nil,
    hostsVirtualActors: Bool,
    people: [CallScope] = [AsAPerson.person],
    installing: @escaping @Sendable (inout ClusterSystemSettings) -> Void = { _ in },
    _ body: (ClusterSystem) async throws -> Result
) async throws -> Result {
    let system = await ClusterSystem(name) { settings in
        configure(&settings, store: store)
        installing(&settings)
        // What objects keep running, unless the test brings its own, to bring them back.
        if settings.plugins[RunningActors.pluginKey] == nil {
            settings.plugins.install(plugin: RunningActors(recovering: []))
        }
    }
    let virtualNode = hostsVirtualActors ? await VirtualNode(actorSystem: system) : nil
    let result: Result
    do {
        if let other {
            system.cluster.join(endpoint: other.cluster.endpoint)
            try await other.cluster.waitFor(system.cluster.node, .up, within: .seconds(10))
        }
        if hostsVirtualActors {
            // Each space made, with a bot: the tester decides for it, and everyone else is a member.
            for (space, inIt) in Dictionary(grouping: people, by: \.space) {
                let reached = try await Space.identified(by: space, on: system)
                if try await reached.status() == nil {
                    try await reached.make(
                        named: SpaceName("Test")!, admins: NonEmptySet(.tester), bot: ollamaBot("Helper"))
                }
                for person in Set(inIt.map(\.person)).subtracting([.tester]) {
                    try await reached.admit(person, into: NonEmptySet(.members))
                }
            }
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

/// A bot called `name`, on a model of Ollama on this machine.
func ollamaBot(_ name: String) -> Bot {
    Bot(
        name: BotName(name)!, instructions: "",
        model: BotModel(
            location: .server(
                ModelServer(software: .ollama, address: .localOllama, key: nil, context: .chosen(.standard))),
            name: ModelName("llama3")!))
}

/// A space called `name`, made by `maker` with `bot` its first bot, which each of `others` then
/// joins with an invite: its id.
func madeSpace(
    _ name: String, by maker: TurgaiDomain.UserID, joinedBy others: [TurgaiDomain.UserID] = [],
    bot: Bot = ollamaBot("Helper"), on system: ClusterSystem
)
    async throws -> SpaceID
{
    let id = SpaceID()
    let space = try await Space.identified(by: id, on: system)
    try await space.make(named: SpaceName(name)!, by: maker, bot: bot)
    for person in others {
        let token = SpaceInviteToken.new()
        try await space.invite(SpaceInvite(hash: token.hash, by: maker, lifetime: .untilUsed))
        try await space.join(with: token.hash, as: person)
    }
    return id
}
