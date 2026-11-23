import DistributedCluster
import RunningActors
import Testing
import TurgaiApplication
import TurgaiCalls
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

    /// A connection runs only once it's added and enabled, and stops once it's turned off or
    /// removed: its space tells its run each time. One that stops by itself says why.
    @Test(.timeLimit(.minutes(1)))
    func aConnectionRunsWhileItsAddedAndEnabled() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem(
            "connections", store: store, hostsVirtualActors: true, people: []
        ) { system in
            let family = try await madeSpace("Family", by: .ann, on: system)
            let space = try await Space.identified(by: family, on: system)
            let run = try await ConnectionRun.of(telegram.id, in: family, on: system)
            // Read as Ann, one of its people, as a page showing it does.
            let ann = try await space.scope(of: .ann)
            let status: @Sendable () async throws -> ConnectionStatus = {
                try await CallChain.$current.withValue(.start(ann, in: nil)) { try await run.status }
            }

            try await space.addConnection(telegram, by: .ann)
            #expect(try await status() == ConnectionStatus(running: false, stopped: nil))

            var enabled = telegram
            enabled.enabled = true
            try await space.changeConnection(enabled, by: .ann)
            // This node runs no platform's connections: it runs, and says why it stopped.
            let refused = ConnectionStatus(running: true, stopped: ConnectionStopped("This node runs no connections."))
            try await eventually { try await status() == refused }

            // Archived, it stops; in use again, it runs.
            try await space.archive(by: .ann)
            #expect(try await status() == ConnectionStatus(running: false, stopped: nil))
            try await space.unarchive(by: .ann)
            try await eventually { try await status() == refused }

            try await space.removeConnection(enabled.id, by: .ann)
            #expect(try await status() == ConnectionStatus(running: false, stopped: nil))
            // No one's call doesn't reach it: it's its space's own.
            await #expect(throws: CallOnBehalfOfNoOne.self) { _ = try await run.status }
            #expect(try await space.connections(for: .ann).isEmpty)
            await #expect(throws: SpaceRefusal.notAllowed) { try await space.connections(for: .bob) }
        }
    }

    /// A connection that was running runs again after a restart with nothing keeping it: the space
    /// directory, as it starts, starts each space it knows, and a space, as it starts, tells its
    /// connections' runs how to run.
    @Test(.timeLimit(.minutes(1)))
    func aSpacesConnectionsRunAgainAfterARestart() async throws {
        let store = MemoryEventStore()
        // The directory as it's kept: the same across the restart, as a database is.
        let directory = SpaceDirectoryStorage.test
        var enabled = telegram
        enabled.enabled = true
        let refused = ConnectionStatus(running: true, stopped: ConnectionStopped("This node runs no connections."))

        let family = try await withClusterSystem(
            "connections-before", store: store, hostsVirtualActors: true, people: []
        ) { system in
            _ = try await system.singleton.host(SpaceDirectory.self, name: SpaceDirectory.singletonName) {
                SpaceDirectory(actorSystem: $0, storage: directory, journal: store, refreshInterval: .milliseconds(10))
            }
            let family = try await madeSpace("Family", by: .ann, on: system)
            let space = try await Space.identified(by: family, on: system)
            try await space.addConnection(enabled, by: .ann)
            // The directory has read that the space is there.
            try await eventually { try await directory.all() == [family] }
            return family
        }

        // Another node, from the same journal and directory: no one calls the space or its run.
        try await withClusterSystem(
            "connections-after", store: store, hostsVirtualActors: true, people: []
        ) { system in
            _ = try await system.singleton.host(SpaceDirectory.self, name: SpaceDirectory.singletonName) {
                SpaceDirectory(actorSystem: $0, storage: directory, journal: store, refreshInterval: .milliseconds(10))
            }
            try await Task.sleep(for: .seconds(2))
            // Only now is it read, as Ann: it's running already.
            let ann = try await Space.identified(by: family, on: system).scope(of: .ann)
            let run = try await ConnectionRun.of(enabled.id, in: family, on: system)
            let status = try await CallChain.$current.withValue(.start(ann, in: nil)) { try await run.status }
            #expect(status == refused)
        }
    }

    /// Once `done` holds, or a few seconds on: refused then.
    private func eventually(_ done: () async throws -> Bool) async throws {
        for _ in 0..<150 where !(try await done()) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try await done())
    }
}
