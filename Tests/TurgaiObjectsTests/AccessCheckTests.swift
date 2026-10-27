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
    private var ann: CallScope { CallScope(UserID("ann"), in: family, as: .member) }
    private var bob: CallScope { CallScope(UserID("bob"), in: family, as: .member) }
    private let counter =
        "actor Counter {\n    var count = 0\n\n    func add() -> Int {\n        count += 1\n        return count\n    }\n}"

    private func `as`<Value: Sendable>(_ scope: CallScope, _ body: () async throws -> Value) async throws -> Value {
        try await CallChain.$current.withValue(.start(scope)) { try await body() }
    }

    private func listed(_ objects: DynamicObjects, to scope: CallScope) async throws -> [String] {
        try await self.as(scope) { try await objects.held().map(\.id.name) }
    }

    @Test(.timeLimit(.minutes(1)))
    func anObjectIsItsMakersUntilShared() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("objects", store: store, hostsVirtualActors: true) { node in
            let objects = try await DynamicObjects.resolve(on: node, scope: .shared)
            let id = try await self.as(ann) {
                try await objects.create(name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))
            }
            let object = try await objects.held(id)

            // Hers: she uses it and sees it; Bob does neither.
            #expect(try await self.as(ann) { try await object.respond("add", arguments: [:]).reply } == .integer(1))
            await #expect(throws: DynamicObjectError.notAllowed(.read)) {
                try await self.as(bob) { _ = try await object.respond("add", arguments: [:]) }
            }
            #expect(try await listed(objects, to: ann) == ["counter"])
            #expect(try await listed(objects, to: bob).isEmpty)

            // Shared with the family to read: Bob uses it and sees it, and still can't change it.
            try await self.as(ann) { try await object.share(with: .group(family), .read) }
            #expect(try await self.as(bob) { try await object.respond("add", arguments: [:]).reply } == .integer(2))
            #expect(try await listed(objects, to: bob) == ["counter"])
            await #expect(throws: DynamicObjectError.notAllowed(.write)) {
                try await self.as(bob) { try await object.share(with: .everyone, .read) }
            }
            await #expect(throws: DynamicObjectError.notAllowed(.write)) {
                try await self.as(bob) { try await objects.remove(id) }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aCallOnBehalfOfNoOneIsRefused() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("objects", store: store, hostsVirtualActors: true) { node in
            let objects = try await DynamicObjects.resolve(on: node, scope: .shared)
            let id = try await self.as(ann) {
                try await objects.create(name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))
            }
            let object = try await objects.held(id)

            await #expect(throws: CallOnBehalfOfNoOne.self) {
                _ = try await object.respond("add", arguments: [:])
            }
        }
    }
}
