import DistributedCluster
import Foundation
import RunningActors
import Testing
import TurgaiCalls
import TurgaiDomain
import TurgaiSpaces

@testable import TurgaiObjects

/// A space's objects are its own: made, named, listed and reached in it alone. The space runs while
/// it has objects, and a node starting wakes it.
@Suite(.serialized)
struct SpaceObjectsTests {
    private let family = SpaceID()
    private let work = SpaceID()
    private var ann: CallScope { CallScope.admin(UserID.ann, in: family) }
    private var bob: CallScope { CallScope.admin(UserID.bob, in: work) }
    private let counter =
        "actor Counter {\n    var count = 0\n\n    func add() -> Int {\n        count += 1\n        return count\n    }\n}"

    private func `as`<Value: Sendable>(_ scope: CallScope, _ body: () async throws -> Value) async throws -> Value {
        try await CallChain.$current.withValue(.start(scope, in: nil)) { try await body() }
    }

    /// Two spaces each make a Counter: neither's is the other's, and neither is listed in the other.
    @Test(.timeLimit(.minutes(1)))
    func eachSpaceNamesItsOwnObjects() async throws {
        try await withClusterSystem(
            "spaces", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann, bob]
        ) { node in
            let families = try await DynamicObjects.of(family, on: node)
            let works = try await DynamicObjects.of(work, on: node)
            let annsID = try await self.as(ann) {
                try await families.create(name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))
            }
            let bobsID = try await self.as(bob) {
                try await works.create(name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))
            }
            #expect(annsID == bobsID)

            let anns = try await families.held(annsID)
            let bobs = try await works.held(bobsID)
            #expect(anns.id != bobs.id)
            #expect(try await self.as(ann) { try await anns.respond("add", arguments: [:]).reply } == .integer(1))
            #expect(try await self.as(bob) { try await bobs.respond("add", arguments: [:]).reply } == .integer(1))
            #expect(try await self.as(ann) { try await families.held().map(\.id.name) } == ["counter"])
            #expect(try await self.as(ann) { try await works.held() }.isEmpty)
        }
    }

    /// An object shared with everyone is shared with everyone in its space: a call from another
    /// space is refused, whoever makes it.
    @Test(.timeLimit(.minutes(1)))
    func noCallFromAnotherSpaceReachesAnObject() async throws {
        try await withClusterSystem(
            "spaces", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann, bob]
        ) { node in
            let families = try await DynamicObjects.of(family, on: node)
            let object = try await self.as(ann) {
                let id = try await families.create(
                    name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))
                let object = try await families.held(id)
                try await object.share(with: .everyone, .write)
                return object
            }
            // Ann herself, coming in through another space, isn't let in either.
            let annAtWork = CallScope.admin(UserID.ann, in: work)
            for outsider in [bob, annAtWork] {
                await #expect(throws: NotAllowed(.read)) {
                    try await self.as(outsider) { _ = try await object.respond("add", arguments: [:]) }
                }
            }
            #expect(try await self.as(ann) { try await object.respond("add", arguments: [:]).reply } == .integer(1))
        }
    }

    /// An object that keeps work running is on its node's running list, kept for whoever made it,
    /// and comes back by its own id as a node starts: let in as them, as its space decides.
    @Test(.timeLimit(.minutes(1)))
    func aRunningObjectComesBackAfterARestart() async throws {
        let recovered = Recovered()
        let running = RunningActors(recovering: [
            .of(DynamicObject.self, dependency: DynamicObject.Config.self, keptFor: CallScope.self) {
                object, config, maker in
                let actor = DynamicObject.callActor(for: config.identity, in: config.space)
                try await CallChain.$current.withValue(.own(actor, for: maker, in: nil)) {
                    try await object.recovered()
                }
                await recovered.add(config.identity)
            }
        ])
        try await withClusterSystem(
            "spaces", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann, bob],
            installing: { $0.plugins.install(plugin: running) }
        ) { node in
            let objects = try await Space.identified(by: family, on: node).objects(for: ann.person)
            let id = try await self.as(ann) {
                try await objects.create(name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))
            }
            // Work kept for Ann, as an object keeps a task of its code: on the list while it runs.
            let work = node.runningActors.keep(
                DynamicObject.self, id: DynamicObject.actorID(for: id, in: family),
                dependency: DynamicObject.Config(space: family, identity: id), for: ann
            ) {
                try? await Task.sleep(for: .seconds(30))
            }
            try await Task.sleep(for: .milliseconds(200))

            await node.runningActors.recover()
            for _ in 0..<100 where await recovered.identities.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            #expect(await recovered.identities == [id])
            work.cancel()
        }
    }
}

/// The objects a test's node brought back.
private actor Recovered {
    private(set) var identities: [ObjectIdentity] = []

    func add(_ identity: ObjectIdentity) {
        identities.append(identity)
    }
}
