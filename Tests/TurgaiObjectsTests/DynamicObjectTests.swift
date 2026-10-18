import DiscoverableActors
import DistributedCluster
import EventSourcing
import Foundation
import Hail
import struct AnyLanguageModel.GeneratedContent
import Testing
import VirtualActors
@testable import TurgaiApplication
@testable import TurgaiObjects

@Suite(.serialized)
struct DynamicObjectTests {
    @Test
    func objectSearchRanksIdentityActionsAndPrefixes() {
        let index = ObjectSearchIndex([
            .init(handle: "coffee-counter", title: "Coffee Counter", actions: "addCup get reset", description: "Counts coffee cups."),
            .init(handle: "reminders", title: "Reminders", actions: "lists", description: "The Mac reminders app."),
            .init(handle: "help", title: "Get Help", actions: "open", description: "Documentation."),
        ])

        #expect(index.search("coffee counter", limit: 5).map(\.handle).first == "coffee-counter")
        #expect(index.search("reset", limit: 5).map(\.handle) == ["coffee-counter"])
        #expect(index.search("reminder", limit: 5).map(\.handle) == ["reminders"])
        #expect(index.search("get", limit: 5).map(\.handle).first == "help")
        #expect(index.search("unknown", limit: 5).isEmpty)
    }

    /// An object announces an event with an `@Event` method, and one holding it as `@Subscribed`
    /// gets each, at its method named like the event: delivered as a message, journaled.
    @Test(.timeLimit(.minutes(2)))
    func anEventReachesTheObjectFollowingIt() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shop, _ in
            try await withDynamicNode(joining: shop, store: store) { node in
                let objects = try await DynamicObjects.resolve(on: node, scope: .shared)
                let counter = "actor CoffeeCounter {\n    var count = 0\n\n    @Event\n    func cupAdded(count: Int)\n\n    func addCup() {\n        count += 1\n        cupAdded(count: count)\n    }\n}"
                let logger = "actor CupLogger {\n    @Subscribed var counter: CoffeeCounter\n    var lastCount = 0\n\n    func onCupAdded(count: Int) {\n        lastCount = count\n    }\n}"
                let counterID = try await objects.create(name: "CoffeeCounter", spec: .new(try Script(code: counter, type: "CoffeeCounter")))
                // The logger is written against the counter's spec, as Turgai gives it the kinds there are.
                let counterSpec = Uses(
                    interface: ModuleInterface(name: Uses.module, source: "actor CoffeeCounter {\n    func addCup() async throws\n    @Event func cupAdded(count: Int)\n}"),
                    names: [:])
                let loggerID = try await objects.create(name: "CupLogger", spec: .new(try Script(code: logger, type: "CupLogger", uses: counterSpec)))
                let coffee = try await DynamicObject.resolve(on: node, identity: counterID)
                let log = try await DynamicObject.resolve(on: node, identity: loggerID)

                #expect(try await coffee.describe().events.keys.sorted() == ["cupAdded"])
                // The logger follows once it has subscribed; until then an event isn't missed, but
                // isn't for it either.
                try await eventually { try await log.read(property: "lastCount") == 0 }
                try await Task.sleep(for: .seconds(2))
                _ = try await coffee.respond("addCup", arguments: [:])
                _ = try await coffee.respond("addCup", arguments: [:])
                try await eventually { try await log.read(property: "lastCount") == .integer(2) }
                #expect(try await log.recent.contains { if case .handled(.event(_, from: "counter"), _) = $0 { true } else { false } })
            }
        }
    }

    /// Another kind of object's values are the Swift types they are: the writer is shown them as
    /// Swift declares them, the code is checked against them, what it publishes is read, and its
    /// values cross both ways as those types.
    @Test(.timeLimit(.minutes(2)))
    func anotherObjectsValuesAreTheirSwiftTypes() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shop, _ in
            try await withDynamicNode(joining: shop, store: store) { node in
                let player = try await Player(actorSystem: node)
                let board = try await Board(actorSystem: node)
                let session = ObjectSession(actorSystem: node, objectCatalog: await ObjectCatalog(actorSystem: node), scopes: [.shared])
                try await eventually { (try await session.list().arrayValue?.count ?? 0) >= 2 }

                let others = await session.others(except: "Bridge")
                let shown = others.declarations.joined(separator: "\n")
                #expect(shown.contains("playing: Track?"))
                #expect(shown.contains("onTrackChanged(track: Track?)"))
                #expect(shown.contains("show(card: Card)"))
                #expect(others.uses.interface.source.contains("struct Track {\n    var title: String\n    var artist: String?\n}"))
                #expect(others.uses.interface.source.contains("case row(items: [Piece])"))
                // The writer is told the values in words, never as declarations to copy.
                let words = others.uses.valuesInWords.joined(separator: "\n")
                #expect(words.contains("- Track: a track, as a player plays it.\n  Fields:\n    title: String\n    artist: String?"))
                #expect(words.contains("- Card: what a board shows. One of:\n    piece(Piece)\n    row(items: [Piece])"))
                #expect(!words.contains("struct"))
                // Another kind of object's card is its spec.
                guard case .markdown(let card) = try await session.card("player") else { return }
                #expect(card.contains("takes:\n- 'play(track: Track) async throws'"))
                #expect(card.contains("publishes:\n- 'playing: Track? { get async throws }'"))
                #expect(card.contains("announces:\n- 'trackChanged(track: Track?)'"))

                let code = """
                    actor Bridge {
                        @Subscribed var player: Player
                        var shown = ""
                        var last: Track? = nil

                        func onTrackChanged(track: Track?) async throws {
                            let now = try await player.playing
                            shown = now?.title ?? "nothing"
                            last = now
                            try await board.show(card: .row(items: [.text(words: shown), .button(label: "Next")]))
                        }
                    }
                    """
                // Reading what another object publishes needs await, as reading another actor's
                // property does.
                let unawaited = code.replacingOccurrences(of: "try await player.playing", with: "player.playing")
                let refused = await ScriptInstance.problems(in: try Script(code: unawaited, type: "Bridge", uses: others.uses))
                #expect(refused.map { $0.written(in: unawaited) } == [
                    "`player.playing` in `let now = player.playing`: expression is 'async' but is not marked with 'await'",
                    "`player.playing` in `let now = player.playing`: property access can throw, but it is not marked with 'try' and the error is not handled",
                ])
                let script = try Script(code: code, type: "Bridge", uses: others.uses)
                #expect(await ScriptInstance.problems(in: script).isEmpty)

                let objects = try await DynamicObjects.resolve(on: node, scope: .shared)
                let bridge = try await DynamicObject.resolve(on: node, identity: try await objects.create(name: "Bridge", spec: .new(script)))
                try await eventually { try await bridge.read(property: "shown") == "" }
                try await Task.sleep(for: .seconds(2))
                try await player.play(Track(title: "Song", artist: nil))
                try await eventually { try await bridge.read(property: "shown") == "Song" }
                #expect(try await board.card == .row(items: [.text(words: "Song"), .button(label: "Next")]))
                // A struct it holds is journaled as `Codable` writes it.
                #expect(try await bridge.read(property: "last") == ["title": "Song"])
                // What it holds reads back, the object it follows as that object's handle.
                #expect(try await session.values("bridge").contains("player: player"))
            }
        }
    }

    /// A followed object's events are handled by its follower's functions named like them: none
    /// handled, or one taking other values, is refused, at its code.
    @Test
    func followingIsCheckedAgainstTheEvents() async throws {
        let shop = Uses(
            interface: ModuleInterface(name: Uses.module, source: "actor Shop {\n    @Event func refundRequested(order: Int)\n}"),
            names: ["shop": "Shop"])
        for (code, refusal) in [
            ("actor Manager {\n    @Subscribed var shop = Shop()\n    func refund(order: Int) {}\n}", "no function handles the events of shop: onRefundRequested(order: Int)"),
            ("actor Manager {\n    @Subscribed var shop = Shop()\n    func onRefundRequested(id: Int) {}\n}", "the event of shop calls onRefundRequested(order: Int)"),
        ] {
            let problems = await ScriptInstance.problems(in: try Script(code: code, type: "Manager", uses: shop))
            #expect(problems.map(\.message) == [refusal])
        }
    }

    /// Objects made here are each listed for the tools that take them, whatever they hold: one
    /// following another's events included.
    @Test(.timeLimit(.minutes(2)))
    func everyMadeObjectIsListed() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shop, _ in
            try await withDynamicNode(joining: shop, store: store) { node in
                let objects = try await DynamicObjects.resolve(on: node, scope: .shared)
                let ann = """
                    actor Ann {
                        var budget = 1000

                        func requestRaise(amount: Int) {
                            if budget >= amount {
                                budget -= amount
                                raiseApproved(amount: amount)
                            } else {
                                raiseDenied(amount: amount)
                            }
                        }

                        @Event func raiseApproved(amount: Int)
                        @Event func raiseDenied(amount: Int)
                    }
                    """
                let annID = try await objects.create(name: "Ann", spec: .new(try Script(code: ann, type: "Ann")))
                let session = ObjectSession(actorSystem: node, objectCatalog: await ObjectCatalog(actorSystem: node), scopes: [.shared])
                let others = await session.others(except: "Bob")
                let bob = """
                    actor Bob {
                        private(set) var pay = 3000

                        @Subscribed
                        private let ann = Ann()

                        func askForRaise(amount: Int) async throws {
                            try await ann.requestRaise(amount: amount)
                        }

                        func onRaiseApproved(amount: Int) {
                            pay += amount
                        }

                        func onRaiseDenied(amount: Int) {}
                    }
                    """
                let bobScript = try Script(code: bob, type: "Bob", uses: others.uses)
                #expect(await ScriptInstance.problems(in: bobScript).isEmpty)
                let bobID = try await objects.create(name: "Bob", spec: .new(bobScript))
                // Each describes itself, and each is listed.
                for identity in [annID, bobID] {
                    _ = try await DynamicObject.resolve(on: node, identity: identity).describe()
                }
                try await eventually { (try? await session.yourObjects()) == ["ann", "bob"] }
                #expect(try await session.yourObjects() == ["ann", "bob"])
                // Using one offers its tools, never another `edit_object` for it alone, which would
                // stand in for the one that changes any of them.
                let bobTools = try await session.usingPage(of: "bob").links.map(\.name)
                #expect(!bobTools.contains("edit_object"))
                let root = try await ObjectTools(session: session).tools().map(\.name)
                #expect(root.contains("edit_object"))
            }
        }
    }

    /// A reference is parsed once, in each of its forms, and written back as it came; data that
    /// only looks like one stays data.
    @Test
    func referencesReadAndWriteAsTheyCame() throws {
        let forms: [(JSONValue, ObjectReference)] = [
            (["object": "ann"], .named("ann")),
            (["object": "Ann", "type": "Ann"], .virtual(id: "Ann", type: "Ann")),
            (["self": true], .itself),
        ]
        for (json, reference) in forms {
            #expect(ObjectReference(json) == reference)
            #expect(try reference.json == json)
        }
        for data: JSONValue in [["object": "ann", "count": 2], ["self": false], ["title": "Song"], "ann", 3] {
            #expect(ObjectReference(data) == nil)
        }
    }

    /// A call to a function of its own is held to what the function declares, as Swift holds it,
    /// in Swift's words: awaited when it's async, tried when it throws, in a function that throws
    /// or catches it.
    @Test
    func ownFunctionsAreCalledAsTheyreDeclared() async throws {
        for (code, refusals) in [
            ("actor Shop {\n    var total = 0\n    func pay(_ amount: Int) {\n        charge(amount)\n    }\n    private func charge(_ amount: Int) throws {\n        total += amount\n    }\n}",
             ["`charge(amount)`: call can throw, but it is not marked with 'try' and the error is not handled"]),
            ("actor Shop {\n    var total = 0\n    func pay(_ amount: Int) {\n        do {\n            try charge(amount)\n        } catch {}\n    }\n    private func charge(_ amount: Int) throws {\n        total += amount\n    }\n}", []),
            ("actor Shop {\n    func pay() {\n        settle()\n    }\n    private func settle() async {}\n}",
             ["`settle()`: 'async' call in a function that does not support concurrency"]),
        ] {
            let problems = await ScriptInstance.problems(in: try Script(code: code, type: "Shop"))
            #expect(problems.map { $0.written(in: code) } == refusals)
        }
    }

    /// A condition binds as Swift binds it, each name read by the conditions after it, and what a
    /// `guard` binds by the code after it; an optional isn't a condition.
    @Test
    func conditionsAreCheckedAsSwiftHasThem() async throws {
        for (code, refusals) in [
            ("actor Shop {\n    var last: Int?\n    func big() -> Bool {\n        if let last, last > 10 {\n            return true\n        }\n        return false\n    }\n}", []),
            ("actor Shop {\n    var last: Int?\n    func big() -> Bool {\n        guard let amount = last, amount > 10 else {\n            return false\n        }\n        return amount > 100\n    }\n}", []),
            ("actor Shop {\n    var last: Int?\n    func paid() -> Bool {\n        if last {\n            return true\n        }\n        return false\n    }\n}",
             ["`last` in `if last {`: optional type 'Int?' cannot be used as a boolean; test for '!= nil' instead"]),
        ] {
            let problems = await ScriptInstance.problems(in: try Script(code: code, type: "Shop"))
            #expect(problems.map { $0.written(in: code) } == refusals)
        }
    }

    /// A file's types are known throughout it, whatever their order, as in Swift: the spec's and
    /// the object's own.
    @Test(.timeLimit(.minutes(2)))
    func typesAreKnownInAnyOrder() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shop, _ in
            try await withDynamicNode(joining: shop, store: store) { node in
                let objects = try await DynamicObjects.resolve(on: node, scope: .shared)
                let uses = Uses(
                    interface: ModuleInterface(
                        name: Uses.module, source: "struct Order {\n    var status: Status\n}\n\nenum Status: String {\n    case placed\n}"),
                    names: [:])
                let code = """
                    actor Shop {
                        var mood: Mood = .calm

                        func order() -> Order {
                            mood = .busy
                            return Order(status: .placed)
                        }
                    }

                    enum Mood {
                        case calm, busy
                    }
                    """
                let script = try Script(code: code, type: "Shop", uses: uses)
                #expect(await ScriptInstance.problems(in: script).isEmpty)
                let identity = try await objects.create(name: "Shop", spec: .new(script))
                let made = try await DynamicObject.resolve(on: node, identity: identity)
                #expect(try await made.respond("order", arguments: [:]).reply == ["status": "placed"])
            }
        }
    }

    /// A reference of one kind to an actor of another fails, whatever it's called with: it never
    /// runs one actor's code on another.
    @Test(.timeLimit(.minutes(2)))
    func aReferenceToAnotherKindOfActorFails() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { node, _ in
            let shop = try await Shop(actorSystem: node)
            await #expect(throws: ResolveError.self) {
                _ = try await DynamicObject.resolve(id: shop.id, using: node).identity
            }
        }
    }

    /// An object reached by name is there wherever the code names it, not only where it calls it:
    /// kept, and called later.
    @Test(.timeLimit(.minutes(2)))
    func anObjectReachedByNameCanBeKept() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shop, _ in
            try await withDynamicNode(joining: shop, store: store) { node in
                let objects = try await DynamicObjects.resolve(on: node, scope: .shared)
                let ann = "actor Ann {\n    func approve(amount: Int) -> Bool {\n        amount < 100\n    }\n}"
                _ = try await objects.create(name: "Ann", spec: .new(try Script(code: ann, type: "Ann")))
                let session = ObjectSession(actorSystem: node, objectCatalog: await ObjectCatalog(actorSystem: node), scopes: [.shared])
                let others = await session.others(except: "Bob")
                let bob = """
                    actor Bob {
                        private var manager: Ann?

                        func hire() {
                            manager = ann
                        }

                        func ask(amount: Int) async throws -> Bool {
                            guard let manager else { return false }
                            return try await manager.approve(amount: amount)
                        }
                    }
                    """
                // What's kept is still another object: unwrapped, it's called as one.
                let unawaited = bob.replacingOccurrences(of: "try await manager.approve", with: "manager.approve")
                let refused = await ScriptInstance.problems(in: try Script(code: unawaited, type: "Bob", uses: others.uses))
                #expect(refused.map { $0.written(in: unawaited) } == [
                    "`manager.approve(amount: amount)` in `return manager.approve(amount: amount)`: expression is 'async' but is not marked with 'await'",
                    "`manager.approve(amount: amount)` in `return manager.approve(amount: amount)`: call can throw, but it is not marked with 'try' and the error is not handled",
                ])
                let bobScript = try Script(code: bob, type: "Bob", uses: others.uses)
                #expect(await ScriptInstance.problems(in: bobScript).isEmpty)
                let bobID = try await objects.create(name: "Bob", spec: .new(bobScript))
                let bobObject = try await DynamicObject.resolve(on: node, identity: bobID)
                _ = try await bobObject.respond("hire", arguments: [:])
                #expect(try await bobObject.respond("ask", arguments: ["amount": 50]).reply == .bool(true))
            }
        }
    }

    /// An object whose code calls itself without end fails once the calls are too deep, with the
    /// circle as the reason, rather than running until memory runs out; and it's what its health
    /// says, for its writer to fix.
    @Test(.timeLimit(.minutes(2)))
    func callsInACircleFailWithTheCircle() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shop, _ in
            try await withDynamicNode(joining: shop, store: store) { node in
                let objects = try await DynamicObjects.resolve(on: node, scope: .shared)
                let code = "actor Ann {\n    func loop() async throws -> Int {\n        return try await ann.loop()\n    }\n}"
                let identity = try await objects.create(name: "Ann", spec: .new(try Script(code: code, type: "Ann")))
                let ann = try await DynamicObject.resolve(on: node, identity: identity)

                await #expect(throws: (any Error).self) { try await ann.respond("loop", arguments: [:]) }
                guard case .failing(let failure) = try await ann.health else {
                    Issue.record("Ann's health isn't failing")
                    return
                }
                #expect(failure.problem.hasPrefix("calls between objects went 65 deep: Ann → Ann → "), "\(failure.problem)")
            }
        }
    }
}

/// Arguments as a model passes them to a typed tool: JSON text.
private func json(_ value: JSONValue) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

private func eventually(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<50 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("Timed out waiting")
}

/// Settings for every node in these tests, journaled to `store`, all able to host the journal
/// and the virtual actors' router, which are cluster singletons and run on the leader.
private func configure(_ settings: inout ClusterSystemSettings, store: MemoryEventStore) {
    settings.bindHost = "127.0.0.1"
    settings.bindPort = PortFinder.findAvailablePort(host: "127.0.0.1")
    settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)
    settings.plugins.install(plugin: ClusterSingletonPlugin())
    let virtualActors = ClusterVirtualActorsPlugin.configuring(&settings)
    settings.plugins.install(plugin: virtualActors)
    settings.plugins.install(plugin: DiscoveryPlugin())
    settings.plugins.install(plugin: ClusterJournalPlugin { _ in store })
}

/// A node for the shop and warehouse, and one for customers, both outliving any dynamic node.
private func withShopNodes<Result>(
    store: MemoryEventStore,
    _ body: (_ shop: ClusterSystem, _ customers: ClusterSystem) async throws -> Result
) async throws -> Result {
    let shop = await ClusterSystem("shop") { configure(&$0, store: store) }
    let customers = await ClusterSystem("customers") { configure(&$0, store: store) }
    defer {
        _ = try? shop.shutdown()
        _ = try? customers.shutdown()
    }
    customers.cluster.join(endpoint: shop.cluster.endpoint)
    try await shop.cluster.waitFor(customers.cluster.node, .up, within: .seconds(10))
    return try await body(shop, customers)
}

/// A node hosting dynamic objects, joined to `other`, for as long as `body` runs.
private func withDynamicNode<Result>(
    joining other: ClusterSystem,
    store: MemoryEventStore,
    _ body: (ClusterSystem) async throws -> Result
) async throws -> Result {
    let node = await ClusterSystem("dynamic") { configure(&$0, store: store) }
    defer { _ = try? node.shutdown() }
    // Hosts the node's virtual actors while it's held.
    let virtualNode = await VirtualNode(actorSystem: node)
    node.cluster.join(endpoint: other.cluster.endpoint)
    try await other.cluster.waitFor(node.cluster.node, .up, within: .seconds(10))
    return try await body(node)
}

/// Events kept in memory, standing in for the file journal.
actor MemoryEventStore: EventStore {
    private var events: [String: [Data]] = [:]

    func persistEvent<Event: Codable & Sendable>(_ event: Event, id: String, sequenceNumber: Int64) throws {
        events[id, default: []].append(try JSONEncoder().encode(event))
    }

    func eventStream<Event: Codable & Sendable>(id: String, fromSequenceNumber: Int64) throws -> EventStream<Event> {
        let stored = Array((events[id] ?? []).enumerated().dropFirst(Int(fromSequenceNumber - 1)))
        let envelopes = try stored.map { offset, data in
            EventEnvelope(
                persistenceID: id, sequenceNumber: Int64(offset + 1),
                event: try JSONDecoder().decode(Event.self, from: data))
        }
        return AsyncThrowingStream { continuation in
            envelopes.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

/// One JSON object with another's members added.
private func merged(_ object: JSONValue, _ other: JSONValue) -> JSONValue {
    guard case .object(let mine) = object, case .object(let theirs) = other else { return object }
    return .object(mine.merging(theirs) { $1 })
}

/// A track, as a player plays it.
@Describable
struct Track: Codable, Sendable, Equatable {
    var title: String
    var artist: String?
}

/// The player started another track.
@Describable
struct TrackChanged: Codable, Sendable, Equatable {
    var track: Track?
}

/// A player, in another kind of object: what it plays, published, and each change announced.
@Discoverable(events: TrackChanged.self)
distributed actor Player {
    typealias ActorSystem = ClusterSystem
    private var current: Track?

    init(actorSystem: ActorSystem) async throws {
        self.actorSystem = actorSystem
        await actorSystem.receptionist.checkIn(try DiscoverableObject.resolve(id: id, using: actorSystem), with: ObjectScope.shared.receptionistKey)
    }

    /// What it plays now.
    public distributed var playing: Track? { current }

    /// Plays `track`.
    public distributed func play(_ track: Track) async {
        current = track
        await announce(TrackChanged(track: track))
    }
}

/// Words or a button.
@Describable
enum Piece: Codable, Sendable, Equatable {
    case text(words: String)
    case button(label: String)
}

/// What a board shows.
@Describable
enum Card: Codable, Sendable, Equatable {
    case piece(Piece)
    case row(items: [Piece])
}

/// A board, in another kind of object: it shows a card.
@Discoverable
distributed actor Board {
    typealias ActorSystem = ClusterSystem
    private var shown: Card?

    init(actorSystem: ActorSystem) async throws {
        self.actorSystem = actorSystem
        await actorSystem.receptionist.checkIn(try DiscoverableObject.resolve(id: id, using: actorSystem), with: ObjectScope.shared.receptionistKey)
    }

    /// What it shows.
    public distributed var card: Card? { shown }

    /// Shows `card`.
    public distributed func show(card: Card) {
        shown = card
    }
}
