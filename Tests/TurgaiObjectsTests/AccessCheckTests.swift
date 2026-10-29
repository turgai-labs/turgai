import DistributedCluster
import Foundation
import Testing
import TurgaiDomain

@testable import TurgaiObjects

/// Every call to a made object is checked where the object lives, against who may read and
/// write it, and what's listed to a caller is what they may read.
@Suite(.serialized)
struct AccessCheckTests {
    private let family = GroupID(rawValue: "family")
    private var ann: CallScope { CallScope(UserID("ann"), in: family, as: .member, allowed: []) }
    private var bob: CallScope { CallScope(UserID("bob"), in: family, as: .member, allowed: []) }
    private let counter =
        "actor Counter {\n    var count = 0\n\n    func add() -> Int {\n        count += 1\n        return count\n    }\n}"

    private func `as`<Value: Sendable>(_ scope: CallScope, _ body: () async throws -> Value) async throws -> Value {
        try await CallChain.$current.withValue(.start(scope, in: nil)) { try await body() }
    }

    private func listed(_ objects: DynamicObjects, to scope: CallScope) async throws -> [String] {
        try await self.as(scope) { try await objects.held().map(\.id.name) }
    }

    @Test(.timeLimit(.minutes(1)))
    func anObjectIsItsMakersUntilShared() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("objects", store: store, hostsVirtualActors: true) { node in
            let objects = try await DynamicObjects.resolve(on: node)
            let id = try await self.as(ann) {
                try await objects.create(name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))
            }
            let object = try await objects.held(id)

            // Hers: she uses it and sees it; Bob does neither.
            #expect(try await self.as(ann) { try await object.respond("add", arguments: [:]).reply } == .integer(1))
            await #expect(throws: NotAllowed(.read)) {
                try await self.as(bob) { _ = try await object.respond("add", arguments: [:]) }
            }
            #expect(try await listed(objects, to: ann) == ["counter"])
            #expect(try await listed(objects, to: bob).isEmpty)

            // Shared with the family to read: Bob uses it and sees it, and still can't change it.
            try await self.as(ann) { try await object.share(with: .group(family), .read) }
            #expect(try await self.as(bob) { try await object.respond("add", arguments: [:]).reply } == .integer(2))
            #expect(try await listed(objects, to: bob) == ["counter"])
            await #expect(throws: NotAllowed(.write)) {
                try await self.as(bob) { try await object.share(with: .everyone, .read) }
            }
            await #expect(throws: NotAllowed(.write)) {
                try await self.as(bob) { try await objects.remove(id) }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aCallOnBehalfOfNoOneIsRefused() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("objects", store: store, hostsVirtualActors: true) { node in
            let objects = try await DynamicObjects.resolve(on: node)
            let id = try await self.as(ann) {
                try await objects.create(name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))
            }
            let object = try await objects.held(id)

            await #expect(throws: CallOnBehalfOfNoOne.self) {
                _ = try await object.respond("add", arguments: [:])
            }
        }
    }

    /// One directory holds everyone's objects: another's, which Bob may not read, is never in his
    /// way, and its name is still taken.
    @Test(.timeLimit(.minutes(1)))
    func anothersObjectIsNotInTheWay() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("objects", store: store, hostsVirtualActors: true) { node in
            let objects = try await DynamicObjects.resolve(on: node)
            let annID = try await self.as(ann) {
                try await objects.create(name: "Tally", spec: .new(try Script(code: counter, type: "Counter")))
            }
            let bobID = try await self.as(bob) {
                try await objects.create(name: "Notes", spec: .new(try Script(code: counter, type: "Counter")))
            }

            // Found by name among what he may read.
            #expect(try await self.as(bob) { try await objects.object(named: "Notes") } == bobID)
            #expect(try await self.as(bob) { try await objects.object(named: "Tally") } == nil)
            #expect(try await self.as(ann) { try await objects.object(named: "Tally") } == annID)
            // His type changes for his object alone.
            let changed = counter.replacingOccurrences(of: "count += 1", with: "count += 2")
            try await self.as(bob) {
                try await objects.update(bobID, source: try Script(code: changed, type: "Counter"))
            }
            #expect(
                try await self.as(bob) { try await objects.held(bobID).respond("add", arguments: [:]).reply }
                    == .integer(2))
            #expect(
                try await self.as(ann) { try await objects.held(annID).respond("add", arguments: [:]).reply }
                    == .integer(1))
            // Her name is still hers.
            await #expect(throws: DynamicObjectsError.nameTaken("Tally")) {
                try await self.as(bob) {
                    _ = try await objects.create(name: "Tally", spec: .new(try Script(code: counter, type: "Counter")))
                }
            }
        }
    }
}
