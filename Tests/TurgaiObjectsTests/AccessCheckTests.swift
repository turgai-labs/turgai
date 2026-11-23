import DiscoverableActors
import DistributedCluster
import Foundation
import Testing
import TurgaiCalls
import TurgaiDomain
import TurgaiSpaces

@testable import TurgaiObjects

/// Every call to a made object is checked where the object lives, against who may read and
/// write it, and what's listed to a caller is what they may read.
@Suite(.serialized)
struct AccessCheckTests {
    private let family = SpaceID()
    private var ann: CallScope { CallScope.member(UserID.ann, in: family) }
    private var bob: CallScope { CallScope.member(UserID.bob, in: family) }
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
        try await withClusterSystem("objects", store: store, hostsVirtualActors: true, people: [ann, bob]) { node in
            let objects = try await DynamicObjects.of(family, on: node)
            let id = try await self.as(ann) {
                try await objects.create(name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))
            }
            let object = try await self.as(ann) { try await objects.held(id) }

            // Hers: she uses it and sees it; Bob does neither.
            #expect(try await self.as(ann) { try await object.respond("add", arguments: [:]).reply } == .integer(1))
            await #expect(throws: NotAllowed(.read)) {
                try await self.as(bob) { _ = try await object.respond("add", arguments: [:]) }
            }
            #expect(try await listed(objects, to: ann) == ["counter"])
            #expect(try await listed(objects, to: bob).isEmpty)

            // Shared with the family to read: Bob uses it and sees it, and still can't change it.
            try await self.as(ann) { try await object.share(with: .group(family, .members), .read) }
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

    /// A removed object's name is free: an object made by it again is a new one, its maker's,
    /// starting from its code, as a name reaches whichever object is there now.
    @Test(.timeLimit(.minutes(1)))
    func aRemovedObjectsNameCanBeMadeAgain() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("objects", store: store, hostsVirtualActors: true, people: [ann, bob]) { node in
            let objects = try await DynamicObjects.of(family, on: node)
            let id = try await self.as(ann) {
                try await objects.create(name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))
            }
            let object = try await self.as(ann) { try await objects.held(id) }
            #expect(try await self.as(ann) { try await object.respond("add", arguments: [:]).reply } == .integer(1))
            try await self.as(ann) { try await objects.remove(id) }

            let again = try await self.as(bob) {
                try await objects.create(name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))
            }
            #expect(again == id)
            // A new one: Bob's, from its code's start, and not Ann's to reach.
            #expect(try await self.as(bob) { try await object.respond("add", arguments: [:]).reply } == .integer(1))
            await #expect(throws: NotAllowed(.read)) {
                try await self.as(ann) { _ = try await object.respond("add", arguments: [:]) }
            }
            #expect(try await listed(objects, to: bob) == ["counter"])
            #expect(try await listed(objects, to: ann).isEmpty)
        }
    }

    /// A call is a message by name to whichever object is there: when what it calls changes or
    /// goes, the call fails with why, and the caller is as it was. Nothing tells it before.
    @Test(.timeLimit(.minutes(1)))
    func aCallToWhatChangedFailsWithWhy() async throws {
        let store = MemoryEventStore()
        func weather(_ forecast: String) -> String { "actor Weather {\n    \(forecast)\n}" }
        let uses = Uses(
            interface: ModuleInterface(
                name: Uses.module,
                source: "actor Weather {\n    init(id: String)\n    func forecast(days: Int) async throws -> String\n}"),
            objects: [:], lasting: ["Weather"])
        let briefing = """
            actor Briefing {
                var mornings = 0

                func morning() async throws -> String {
                    mornings += 1
                    return try await Weather(id: "weather").forecast(days: 3)
                }
            }
            """
        try await withClusterSystem("objects", store: store, hostsVirtualActors: true, people: [ann, bob]) { node in
            let objects = try await DynamicObjects.of(family, on: node)
            let weatherID = try await self.as(ann) {
                try await objects.create(
                    name: "Weather",
                    spec: .new(
                        try Script(code: weather("func forecast(days: Int) -> String { \"sunny\" }"), type: "Weather")))
            }
            let briefingID = try await self.as(ann) {
                try await objects.create(
                    name: "Briefing", spec: .new(try Script(code: briefing, type: "Briefing", uses: uses)))
            }
            let desk = try await self.as(ann) { try await objects.held(briefingID) }
            func morning() async throws -> JSONValue {
                try await self.as(ann) { try await desk.respond("morning", arguments: [:]).reply }
            }
            func failure() async -> String {
                do {
                    _ = try await morning()
                    return "it didn't fail"
                } catch {
                    return String(describing: error)
                }
            }
            #expect(try await morning() == .string("sunny"))

            // What it called is gone, takes another type, or answers with another.
            for (changed, why) in [
                ("func summary() -> String { \"sunny\" }", "takes no `forecast`"),
                ("func forecast(days: String) -> String { \"sunny\" }", "`days`"),
                ("func forecast(days: Int) -> Int { 7 }", "isn't"),
            ] {
                try await self.as(ann) {
                    try await objects.update(weatherID, source: try Script(code: weather(changed), type: "Weather"))
                }
                let failed = await failure()
                #expect(failed.contains(why), "\(changed): \(failed)")
            }
            // And when it's gone with its type: no object or type of it is here.
            try await self.as(ann) { try await objects.remove(weatherID) }
            #expect(await failure().contains("Weather"))
            // Each failed call left the caller as it was: only the first morning counted.
            #expect(try await self.as(ann) { try await desk.read(property: "mornings") } == .integer(1))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aCallOnBehalfOfNoOneIsRefused() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("objects", store: store, hostsVirtualActors: true, people: [ann, bob]) { node in
            let objects = try await DynamicObjects.of(family, on: node)
            let id = try await self.as(ann) {
                try await objects.create(name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))
            }
            let object = try await self.as(ann) { try await objects.held(id) }

            // No one asked, and nothing says what they may do.
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
        try await withClusterSystem("objects", store: store, hostsVirtualActors: true, people: [ann, bob]) { node in
            let objects = try await DynamicObjects.of(family, on: node)
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
