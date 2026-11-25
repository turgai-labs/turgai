import DistributedCluster
import Foundation
import RunningActors
import Testing
import TurgaiCalls
import TurgaiDomain
import TurgaiPeople
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

            let anns = try await self.as(ann) { try await families.held(annsID) }
            let bobs = try await self.as(bob) { try await works.held(bobsID) }
            #expect(anns.id != bobs.id)
            #expect(try await self.as(ann) { try await anns.respond("add", arguments: [:]).reply } == .integer(1))
            #expect(try await self.as(bob) { try await bobs.respond("add", arguments: [:]).reply } == .integer(1))
            #expect(try await self.as(ann) { try await families.held().map(\.id.name) } == ["counter"])
            // Another space's objects aren't hers to list: the call is refused, not answered with none.
            await #expect(throws: NotAllowed(.read)) { _ = try await self.as(ann) { try await works.held() } }
        }
    }

    /// A space lists its own objects for one of its people: those it has from the start, and those
    /// made in it. No one who isn't in the space is told it.
    @Test(.timeLimit(.minutes(1)))
    func aSpaceListsItsOwnObjects() async throws {
        try await withClusterSystem(
            "spaces", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann]
        ) { node in
            let families = try await DynamicObjects.of(family, on: node)
            let counterID = try await self.as(ann) {
                try await families.create(name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))
            }
            // Its card is its own: read from it, as any of what it publishes is.
            let card = try await self.as(ann) { try await families.held(counterID).card }
            guard case .markdown(let written) = card else { return }
            #expect(written.hasPrefix("# Counter"), "\(written)")
            #expect(written.contains("count: 0") && written.contains("actor Counter"), "\(written)")
            let space = try await Space.identified(by: family, on: node)
            let listed = try await space.objects(for: .ann)
            #expect(
                Set(listed.map(\.type)).isSuperset(of: ["Scheduler", "Timers", "Counter"]), "\(listed.map(\.type))")
            // Its bots aren't among them: they're listed apart, for a turn to ask, each by what it's called.
            #expect(!listed.contains { $0.description == "Helper" }, "\(listed.map(\.description))")
            #expect(try await space.botObjects(for: .ann, besides: nil).map(\.description) == ["Helper"])
            // Every one of them is the space's own, as its id says.
            let ids = listed.map { entry -> String in
                if case .virtual(let id) = entry.id { id.rawValue } else { "\(entry.id)" }
            }
            #expect(ids.allSatisfy { $0.contains(family.rawValue.uuidString) }, "\(ids)")

            await #expect(throws: SpaceRefusal.notInIt) { _ = try await space.objects(for: .guest(UUID())) }
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

    /// An object's own work may use only what its space allows that object. One that follows
    /// another its maker made isn't let in by that: it asks its space, as it asks for a tool, and
    /// follows once whoever decides allows it.
    @Test(.timeLimit(.minutes(2)))
    func anObjectAsksToUseAnotherAndFollowsOnceAllowed() async throws {
        let counter =
            "actor CoffeeCounter {\n    var count = 0\n\n    /// A cup was added.\n    @Event\n    struct CupAdded {\n        var count: Int\n    }\n\n    func addCup() {\n        count += 1\n        announce(CupAdded(count: count))\n    }\n}"
        let logger =
            "actor CupLogger {\n    @Subscribed var counter = CoffeeCounter(id: \"coffee-counter\")\n    var lastCount = 0\n\n    func onCupAdded(_ cupAdded: CoffeeCounter.CupAdded) {\n        lastCount = cupAdded.count\n    }\n}"
        let family = family
        let ann = ann
        try await withClusterSystem(
            "asking", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann]
        ) { node in
            let space = try await Space.identified(by: family, on: node)
            let chat = ConversationID(channel: ChannelID("turgai"), externalAddress: .init(UUID().uuidString))
            try await space.start(chat, with: nil, by: .tester)
            let (counterID, loggerID) = try await self.as(ann) {
                let objects = try await DynamicObjects.of(family, on: node)
                let counterID = try await objects.create(
                    name: "CoffeeCounter", spec: .new(try Script(code: counter, type: "CoffeeCounter")))
                let uses = Uses(
                    interface: Uses.interface(of: [
                        Uses.Object(description: try await objects.held(counterID).describe(), publishes: true)
                    ]),
                    objects: [:], lasting: ["CoffeeCounter"])
                let loggerID = try await objects.create(
                    name: "CupLogger", spec: .new(try Script(code: logger, type: "CupLogger", uses: uses)))
                return (counterID, loggerID)
            }
            let itself = try Party(DynamicObject.actorID(for: loggerID, in: family))
            let wanted = ExactRequest.use(try #require(DynamicObject.actorID(for: counterID, in: family).spaceActor))

            // Refused, it asks: one request, however often it tries again.
            var waiting: [AccessRequest] = []
            for _ in 0..<100 where waiting.isEmpty {
                waiting = try await space.waiting()
                if waiting.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
            }
            try await Task.sleep(for: .seconds(2))
            waiting = try await space.waiting()
            #expect(waiting.map(\.request) == [wanted])
            #expect(waiting.map(\.by) == [itself])
            #expect(wanted.description == "use coffee-counter")

            // Allowed always, by someone who decides for the space: it follows, and hears a cup.
            try await space.answer(try #require(waiting.first).id, .always, by: .tester, in: chat)
            #expect(try await space.waiting().isEmpty)
            try await self.as(ann) {
                let objects = try await DynamicObjects.of(family, on: node)
                let coffee = try await objects.held(counterID)
                let log = try await objects.held(loggerID)
                var heard = try await log.read(property: "lastCount")
                for _ in 0..<50 where heard == .integer(0) {
                    _ = try await coffee.respond("addCup", arguments: [:])
                    try await Task.sleep(for: .milliseconds(200))
                    heard = try await log.read(property: "lastCount")
                }
                #expect(heard != .integer(0))
            }
        }
    }

    /// An object that follows another keeps that work running, so it's on its node's running list
    /// and comes back as a node starts: as its own work, with what its space says it may do then.
    /// Nothing about what it may do was kept: what's shared with it is read anew.
    @Test(.timeLimit(.minutes(2)))
    func anObjectsOwnWorkComesBackAfterARestart() async throws {
        let store = MemoryEventStore()
        let running: @Sendable () -> RunningActors = { RunningActors(recovering: [DynamicObject.recovery]) }
        let counter =
            "actor CoffeeCounter {\n    var count = 0\n\n    /// A cup was added.\n    @Event\n    struct CupAdded {\n        var count: Int\n    }\n\n    func addCup() {\n        count += 1\n        announce(CupAdded(count: count))\n    }\n}"
        let logger =
            "actor CupLogger {\n    @Subscribed var counter = CoffeeCounter(id: \"coffee-counter\")\n    var lastCount = 0\n\n    func onCupAdded(_ cupAdded: CoffeeCounter.CupAdded) {\n        lastCount = cupAdded.count\n    }\n}"
        let family = family
        let ann = ann

        let (counterID, loggerID, heardBefore) = try await withClusterSystem(
            "before", store: store, hostsVirtualActors: true, people: [ann],
            installing: { $0.plugins.install(plugin: running()) }
        ) { node in
            try await self.as(ann) {
                let objects = try await DynamicObjects.of(family, on: node)
                let counterID = try await objects.create(
                    name: "CoffeeCounter", spec: .new(try Script(code: counter, type: "CoffeeCounter")))
                let coffee = try await objects.held(counterID)
                let uses = Uses(
                    interface: Uses.interface(of: [
                        Uses.Object(description: try await coffee.describe(), publishes: true)
                    ]),
                    objects: [:], lasting: ["CoffeeCounter"])
                let loggerID = try await objects.create(
                    name: "CupLogger", spec: .new(try Script(code: logger, type: "CupLogger", uses: uses)))
                // The counter is shared with the logger itself, whose own work following is.
                try await coffee.share(
                    with: Audience(try Party(DynamicObject.actorID(for: loggerID, in: family))), .read)
                // It follows: a cup added reaches it.
                let log = try await objects.held(loggerID)
                for _ in 0..<100 {
                    _ = try await coffee.respond("addCup", arguments: [:])
                    if try await log.read(property: "lastCount") != .integer(0) { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                let heard = try await log.read(property: "lastCount")
                #expect(heard != .integer(0))
                return (counterID, loggerID, heard)
            }
        }

        // The node is gone, and another starts from the same journal: nothing calls the logger.
        try await withClusterSystem(
            "after", store: store, hostsVirtualActors: true, people: [ann],
            installing: { $0.plugins.install(plugin: running()) }
        ) { node in
            await node.runningActors.recover()
            // It follows again, as itself, with no one having called it: a cup added now reaches
            // it. Only then is it read, which would start it too late to hear that cup.
            try await Task.sleep(for: .seconds(2))
            try await self.as(ann) {
                let objects = try await DynamicObjects.of(family, on: node)
                _ = try await objects.held(counterID).respond("addCup", arguments: [:])
                try await Task.sleep(for: .seconds(1))
                #expect(try await objects.held(loggerID).read(property: "lastCount") != heardBefore)
            }
        }
    }
}
