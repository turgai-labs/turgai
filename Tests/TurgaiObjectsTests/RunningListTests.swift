import DistributedCluster
import Foundation
import Testing
import VirtualActors

@testable import RunningActors

/// The running list: only the node run keeping an actor takes it off.
@Suite
struct RunningListTests {
    private let id = VirtualActorID(rawValue: "counter")

    private func entry(keptBy keeper: String) -> RunningEntry {
        RunningEntry(id: id, typeName: "Counter", dependency: Data(), keptFor: Data(), keeper: keeper)
    }

    /// Kept by a node's first run, then by its next run once it moved: the first run's late
    /// "stopped" leaves it on the list; the keeper's own takes it off.
    @Test(.timeLimit(.minutes(1)))
    func onlyItsKeeperTakesAnActorOff() async throws {
        try await withClusterSystem("running", store: MemoryEventStore(), hostsVirtualActors: false, people: []) {
            node in
            let list = try await RunningList(actorSystem: node)
            try await list.started(entry(keptBy: "first run"))
            try await list.started(entry(keptBy: "next run"))

            try await list.stopped(id, keptBy: "first run")
            #expect(try await list.entries() == [entry(keptBy: "next run")])

            try await list.stopped(id, keptBy: "next run")
            #expect(try await list.entries().isEmpty)
        }
    }
}
