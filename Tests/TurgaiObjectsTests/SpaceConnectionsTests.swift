import DistributedCluster
import RunningActors
import Testing
import TurgaiApplication
import TurgaiDomain
import TurgaiSpaces

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A space's connections: who configures them, and that each runs only once it's added and
/// enabled, again when it changes, and no more once it's removed.
@Suite
struct SpaceConnectionsTests {
    private let telegram = Connection(
        label: ConnectionLabel("Family chat")!, enabled: false, platform: .telegram(TelegramAccess()))

    /// Only someone who may configure its connections adds, changes and removes one.
    @Test func whoeverMayConfigureConnectionsConfiguresThem() throws {
        let family = SpaceID()
        var state = SpaceDecider.evolve(
            SpaceDecider.initial(family),
            try SpaceDecider.decide(
                .make(named: SpaceName("Family")!, by: .ann, bot: ollamaBot("Helper")), SpaceDecider.initial(family)))
        state = SpaceDecider.evolve(state, try SpaceDecider.decide(.admit(.bob, into: NonEmptySet(.members)), state))

        #expect(throws: SpaceRefusal.notAllowed) { try SpaceDecider.decide(.addConnection(telegram, by: .bob), state) }
        state = SpaceDecider.evolve(state, try SpaceDecider.decide(.addConnection(telegram, by: .ann), state))
        #expect(state.space?.connections[telegram.id] == telegram)
        #expect(throws: SpaceRefusal.connectionExists(telegram.id)) {
            try SpaceDecider.decide(.addConnection(telegram, by: .ann), state)
        }
        #expect(try SpaceDecider.decide(.changeConnection(telegram, by: .ann), state).isEmpty)
        let other = Connection(label: ConnectionLabel("Other")!, enabled: true, platform: .telegram(TelegramAccess()))
        #expect(throws: SpaceRefusal.noSuchConnection(other.id)) {
            try SpaceDecider.decide(.changeConnection(other, by: .ann), state)
        }
        state = SpaceDecider.evolve(state, try SpaceDecider.decide(.removeConnection(telegram.id, by: .ann), state))
        #expect(state.space?.connections.isEmpty == true)
        #expect(try SpaceDecider.decide(.removeConnection(telegram.id, by: .ann), state).isEmpty)
    }

    /// A connection runs only once it's added and enabled, as its space's events say, and stops
    /// once it's turned off or removed: its run reads the facts from the space each time. One that
    /// stops by itself says why.
    @Test(.timeLimit(.minutes(1)))
    func aConnectionRunsWhileItsAddedAndEnabled() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem(
            "connections", store: store, hostsVirtualActors: true, people: []
        ) { system in
            _ = try await system.singleton.host(ConnectionPolicy.self, name: ConnectionPolicy.singletonName) {
                ConnectionPolicy(actorSystem: $0, offset: .test, journal: store, refreshInterval: .milliseconds(10))
            }
            let family = try await madeSpace("Family", by: .ann, on: system)
            let space = try await Space.identified(by: family, on: system)
            let run = try await ConnectionRun.of(telegram.id, in: family, on: system)

            try await space.addConnection(telegram, by: .ann)
            try await Task.sleep(for: .milliseconds(100))
            #expect(try await run.status == ConnectionStatus(running: false, stopped: nil))

            var enabled = telegram
            enabled.enabled = true
            try await space.changeConnection(enabled, by: .ann)
            // This node runs no platform's connections: it runs, and says why it stopped.
            let refused = ConnectionStatus(running: true, stopped: ConnectionStopped("This node runs no connections."))
            try await eventually { try await run.status == refused }

            try await space.removeConnection(enabled.id, by: .ann)
            try await eventually { try await run.status == ConnectionStatus(running: false, stopped: nil) }
            #expect(try await space.connections(for: .ann).isEmpty)
            await #expect(throws: SpaceRefusal.notAllowed) { try await space.connections(for: .bob) }
        }
    }

    /// Once `done` holds, or a few seconds on: refused then.
    private func eventually(_ done: () async throws -> Bool) async throws {
        for _ in 0..<150 where !(try await done()) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try await done())
    }
}
