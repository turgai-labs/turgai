import DistributedCluster
import Foundation
import Testing
import TurgaiDomain
import TurgaiSpaces

/// The space directory: each person's list, kept from the spaces' own events, never told by them.
@Suite
struct SpaceDirectoryTests {
    /// A person's list follows the spaces they make, join, and leave, and what those are called.
    @Test func aPersonsListFollowsTheSpacesTheyreIn() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("directory", store: store, hostsVirtualActors: true) { system in
            _ = try await system.singleton.host(SpaceDirectory.self, name: SpaceDirectory.singletonName) {
                SpaceDirectory(actorSystem: $0, storage: .test, journal: store, refreshInterval: .milliseconds(10))
            }
            let spaces = Spaces(actorSystem: system, turgaisOwn: SpaceID())
            let family = try await spaces.make(named: SpaceName("Family")!, by: .ann)
            let work = try await spaces.make(named: SpaceName("Work")!, by: .ann)
            let (_, token) = try await spaces.invite(to: family.id, by: .ann, for: .untilUsed)
            _ = try await spaces.join(family.id, with: token, as: .bob)

            let annsSpaces = [
                SpaceListing(id: family.id, name: SpaceName("Family")!, role: .admin, status: .active),
                SpaceListing(id: work.id, name: SpaceName("Work")!, role: .admin, status: .active),
            ]
            #expect(try await list(of: .ann, in: spaces, once: annsSpaces) == annsSpaces)
            let bobsSpaces = [SpaceListing(id: family.id, name: SpaceName("Family")!, role: .member, status: .active)]
            #expect(try await list(of: .bob, in: spaces, once: bobsSpaces) == bobsSpaces)

            _ = try await spaces.rename(family.id, to: SpaceName("Home")!, by: .ann)
            try await spaces.leave(family.id, as: .bob)
            let renamed = [
                SpaceListing(id: family.id, name: SpaceName("Home")!, role: .admin, status: .active),
                SpaceListing(id: work.id, name: SpaceName("Work")!, role: .admin, status: .active),
            ]
            #expect(try await list(of: .ann, in: spaces, once: renamed) == renamed)
            #expect(try await list(of: .bob, in: spaces, once: []) == [])
        }
    }

    /// An archived space stays on its people's lists, marked archived, until it's used again; Turgai's
    /// own isn't archived.
    @Test func anArchivedSpaceStaysListed() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("archive", store: store, hostsVirtualActors: true) { system in
            _ = try await system.singleton.host(SpaceDirectory.self, name: SpaceDirectory.singletonName) {
                SpaceDirectory(actorSystem: $0, storage: .test, journal: store, refreshInterval: .milliseconds(10))
            }
            let turgais = try await Spaces(actorSystem: system, turgaisOwn: SpaceID()).make(
                named: SpaceName("Turgai")!, by: .ann)
            let spaces = Spaces(actorSystem: system, turgaisOwn: turgais.id)
            let family = try await spaces.make(named: SpaceName("Family")!, by: .ann)
            await #expect(throws: SpaceRefusal.turgaisOwn) { try await spaces.archive(turgais.id, by: .ann) }

            #expect(try await spaces.archive(family.id, by: .ann).status == .archived)
            let archived = [
                SpaceListing(id: turgais.id, name: SpaceName("Turgai")!, role: .admin, status: .active),
                SpaceListing(id: family.id, name: SpaceName("Family")!, role: .admin, status: .archived),
            ]
            #expect(try await list(of: .ann, in: spaces, once: archived) == archived)

            #expect(try await spaces.unarchive(family.id, by: .ann).status == .active)
            let active = [
                SpaceListing(id: turgais.id, name: SpaceName("Turgai")!, role: .admin, status: .active),
                SpaceListing(id: family.id, name: SpaceName("Family")!, role: .admin, status: .active),
            ]
            #expect(try await list(of: .ann, in: spaces, once: active) == active)
        }
    }

    /// `person`'s list once it's `expected`, or as it is after two seconds: the directory follows
    /// the spaces a moment behind.
    private func list(of person: UserID, in spaces: Spaces, once expected: [SpaceListing]) async throws
        -> [SpaceListing]
    {
        var listed = try await spaces.list(for: person)
        for _ in 0..<200 where listed != expected {
            try await Task.sleep(for: .milliseconds(10))
            listed = try await spaces.list(for: person)
        }
        return listed
    }
}
