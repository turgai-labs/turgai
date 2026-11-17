import DistributedCluster
import Foundation
import Testing
import TurgaiDomain
import TurgaiSpaces

/// The space directory: each person's spaces, kept from the spaces' own events, never told by them.
@Suite
struct SpaceDirectoryTests {
    /// A person's list follows the spaces they make, join, and leave; one archived stays on it.
    @Test func aPersonsListFollowsTheSpacesTheyreIn() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("directory", store: store, hostsVirtualActors: true) { system in
            let directory = try await system.singleton.host(
                SpaceDirectory.self, name: SpaceDirectory.singletonName
            ) {
                SpaceDirectory(actorSystem: $0, storage: .test, journal: store, refreshInterval: .milliseconds(10))
            }
            let familyID = SpaceID()
            let workID = SpaceID()
            let family = try await Space.identified(by: familyID, on: system)
            let work = try await Space.identified(by: workID, on: system)
            try await family.make(named: SpaceName("Family")!, by: .ann, bot: ollamaBot("Helper"))
            try await work.make(named: SpaceName("Work")!, by: .ann, bot: ollamaBot("Helper"))
            let token = SpaceInviteToken.new()
            try await family.invite(SpaceInvite(hash: token.hash, by: .ann, lifetime: .untilUsed))
            try await family.join(with: token.hash, as: .bob)

            #expect(try await list(of: .ann, in: directory, once: [familyID, workID]) == [familyID, workID])
            #expect(try await list(of: .bob, in: directory, once: [familyID]) == [familyID])

            try await family.archive(by: .ann)
            try await family.leave(.bob)
            #expect(try await list(of: .bob, in: directory, once: []) == [])
            #expect(try await list(of: .ann, in: directory, once: [familyID, workID]) == [familyID, workID])
        }
    }

    /// `person`'s spaces once they're `expected`, or as they are after two seconds: the directory
    /// follows the spaces a moment behind.
    private func list(of person: UserID, in directory: SpaceDirectory, once expected: [SpaceID]) async throws
        -> [SpaceID]
    {
        var listed = try await directory.spaces(of: person)
        for _ in 0..<200 where listed != expected {
            try await Task.sleep(for: .milliseconds(10))
            listed = try await directory.spaces(of: person)
        }
        return listed
    }
}
