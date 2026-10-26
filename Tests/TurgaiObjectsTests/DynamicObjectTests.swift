import DiscoverableActors
import DistributedCluster
import EventSourcing
import Foundation
import Hail
import Testing
import TurgaiDomain
import VirtualActors

import struct AnyLanguageModel.GeneratedContent

@testable import TurgaiApplication
@testable import TurgaiObjects

@Suite(.serialized, .asTheRuntime)
struct DynamicObjectTests {
    @Test
    func objectSearchRanksIdentityActionsAndPrefixes() {
        let index = ObjectSearchIndex([
            .init(
                handle: "coffee-counter", title: "Coffee Counter", actions: "addCup get reset",
                description: "Counts coffee cups."),
            .init(handle: "reminders", title: "Reminders", actions: "lists", description: "The Mac reminders app."),
            .init(handle: "help", title: "Get Help", actions: "open", description: "Documentation."),
        ])

        #expect(index.search("coffee counter", limit: 5).map(\.handle).first == "coffee-counter")
        #expect(index.search("reset", limit: 5).map(\.handle) == ["coffee-counter"])
        #expect(index.search("reminder", limit: 5).map(\.handle) == ["reminders"])
        #expect(index.search("get", limit: 5).map(\.handle).first == "help")
        #expect(index.search("unknown", limit: 5).isEmpty)
    }

    /// A call made through a type runs only on an object of that type: an object given as a
    /// `Wallet` is called as one, and one that isn't refuses, saying what it is.
    @Test(.timeLimit(.minutes(2)))
    func aCallThroughATypeRunsOnlyOnThatType() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shop, _ in
            try await withDynamicNode(joining: shop, store: store) { node in
                let objects = try await DynamicObjects.resolve(on: node, scope: .shared)
                _ = try await objects.create(
                    name: "Wallet",
                    spec: .new(try Script(code: "actor Wallet {\n    func balance() -> Int { 5 }\n}", type: "Wallet")))
                let clockID = try await objects.create(
                    name: "Clock",
                    spec: .new(try Script(code: "actor Clock {\n    func balance() -> Int { 9 }\n}", type: "Clock")))
                let others = Uses(
                    interface: ModuleInterface(
                        name: Uses.module,
                        source:
                            "actor Wallet {\n    func balance() async throws -> Int\n}\n\nactor Clock {\n    func balance() async throws -> Int\n}"
                    ),
                    objects: [:])
                let teller = """
                    actor Teller {
                        func check(wallet: Wallet) async throws -> Int {
                            try await wallet.balance()
                        }

                        func checkAll(_ wallets: [Wallet]) async throws -> Int {
                            wallets.count
                        }
                    }
                    """
                let tellerID = try await objects.create(
                    name: "Teller", spec: .new(try Script(code: teller, type: "Teller", uses: others)))
                let desk = try await DynamicObjects.resolve(on: node, scope: .shared).held(tellerID)

                let paid = try await desk.respond("check", arguments: ["wallet": ["object": "Wallet"]])
                #expect(paid.reply == .integer(5))
                // A reference that says what it is is refused where it's given, before the method
                // runs, wherever it is in what's given.
                let clock = try await DynamicObjects.resolve(on: node, scope: .shared).held(clockID)
                let bare = try JSONValue(encoding: try ActorReference(clock))
                guard case .object(var typed) = bare else { throw CancellationError() }
                typed["type"] = "Clock"
                let refused = await #expect(throws: (any Error).self) {
                    _ = try await desk.respond("check", arguments: ["wallet": .object(typed)])
                }
                #expect(
                    "\(refused.map { String(describing: $0) } ?? "")".contains("`wallet`: a 'Clock' isn't a 'Wallet'"))
                let inside = await #expect(throws: (any Error).self) {
                    _ = try await desk.respond("checkAll", arguments: ["_0": [.object(typed)]])
                }
                #expect(
                    "\(inside.map { String(describing: $0) } ?? "")".contains(
                        "`wallets[0]`: a 'Clock' isn't a 'Wallet'"))
                // One that doesn't say, by its id or by its name, is refused by the object it's
                // called on.
                let named = await #expect(throws: (any Error).self) {
                    _ = try await desk.respond("check", arguments: ["wallet": ["object": "Clock"]])
                }
                #expect("\(named.map { String(describing: $0) } ?? "")".contains("It's a `Clock`, not a `Wallet`."))
                let called = await #expect(throws: (any Error).self) {
                    _ = try await desk.respond("check", arguments: ["wallet": bare])
                }
                #expect("\(called.map { String(describing: $0) } ?? "")".contains("It's a `Clock`, not a `Wallet`."))
            }
        }
    }

    /// An object announces an event with an `@Event` method, and one holding it as `@Subscribed`
    /// gets each, at its method named like the event: delivered as a message, journaled.
    @Test(.timeLimit(.minutes(2)))
    func anEventReachesTheObjectFollowingIt() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shop, _ in
            try await withDynamicNode(joining: shop, store: store) { node in
                let objects = try await DynamicObjects.resolve(on: node, scope: .shared)
                let counter =
                    "actor CoffeeCounter {\n    var count = 0\n\n    @Event\n    func cupAdded(count: Int)\n\n    func addCup() {\n        count += 1\n        cupAdded(count: count)\n    }\n}"
                let logger =
                    "actor CupLogger {\n    @Subscribed var counter = CoffeeCounter(id: \"coffee-counter\")\n    var lastCount = 0\n\n    func onCupAdded(count: Int) {\n        lastCount = count\n    }\n}"
                let counterID = try await objects.create(
                    name: "CoffeeCounter", spec: .new(try Script(code: counter, type: "CoffeeCounter")))
                // The logger is written against the counter's spec, as Turgai gives it the types there are.
                let counterSpec = Uses(
                    interface: ModuleInterface(
                        name: Uses.module,
                        source:
                            "actor CoffeeCounter {\n    init(id: String)\n    func addCup() async throws\n    @Event func cupAdded(count: Int)\n}"
                    ),
                    objects: [:])
                let loggerID = try await objects.create(
                    name: "CupLogger", spec: .new(try Script(code: logger, type: "CupLogger", uses: counterSpec)))
                let coffee = try await DynamicObjects.resolve(on: node, scope: .shared).held(counterID)
                let log = try await DynamicObjects.resolve(on: node, scope: .shared).held(loggerID)

                #expect(try await coffee.describe().events.keys.sorted() == ["cupAdded"])
                // The logger follows once it has subscribed; until then an event isn't missed, but
                // isn't for it either.
                try await eventually { try await log.read(property: "lastCount") == 0 }
                try await Task.sleep(for: .seconds(2))
                _ = try await coffee.respond("addCup", arguments: [:])
                _ = try await coffee.respond("addCup", arguments: [:])
                try await eventually { try await log.read(property: "lastCount") == .integer(2) }
                #expect(
                    try await log.recent.contains {
                        if case .handled(.event(_, from: "counter"), _) = $0 { true } else { false }
                    })
            }
        }
    }

    /// A `@Subscribed` property is given its object as any property is: `Type(id:)`. The attribute
    /// takes nothing.
    @Test
    func aSubscribedPropertySaysWhatItFollows() async throws {
        let uses = Uses(
            interface: ModuleInterface(
                name: Uses.module,
                source:
                    "actor CoffeeCounter {\n    init(id: String)\n    @Event func cupAdded(count: Int)\n}\n\nactor Clock {\n    init(id: String)\n    @Event func ticked(at: Int)\n}"
            ),
            objects: [
                ObjectIdentity(rawValue: "teaCounter"): "CoffeeCounter",
                ObjectIdentity(rawValue: "coffeeCounter"): "CoffeeCounter", ObjectIdentity(rawValue: "clock"): "Clock",
            ])
        func refusals(_ property: String) async throws -> [String] {
            let code = "actor CupLogger {\n    \(property)\n\n    func onCupAdded(count: Int) {}\n}"
            return await ScriptInstance.problems(in: try Script(code: code, type: "CupLogger", uses: uses)).map(
                \.message)
        }
        #expect(try await refusals("@Subscribed var tea = CoffeeCounter(id: \"tea-counter\")").isEmpty)
        #expect(
            try await refusals("@Subscribed(id: \"tea-counter\") var tea = CoffeeCounter(id: \"tea-counter\")") == [
                "@Subscribed takes no arguments: it follows the object its property holds"
            ])
        #expect(
            try await refusals("@Subscribed var tea = Clock(id: \"clock\")") == [
                "no function handles the events of clock: onTicked(at: Int)"
            ])
    }

    /// An `init` other than `init(id: String)` is never called, and each property without an
    /// initial value needs one: said in Swift's words, of the code as written.
    @Test
    func anInitThatIsNeverCalledSaysWhatNeedsAValue() async throws {
        let uses = Uses(
            interface: ModuleInterface(
                name: Uses.module,
                source:
                    "actor Ann {\n    init(id: String)\n    func approveRaise(_ amount: Int) async throws -> Bool\n}"),
            objects: [ObjectIdentity(rawValue: "ann"): "Ann"])
        func refusals(_ code: String) async throws -> [String] {
            await ScriptInstance.problems(in: try Script(code: code, type: "Bob", uses: uses)).map {
                $0.written(in: code)
            }
        }
        let given =
            "actor Bob {\n    let ann: Ann\n    var pay: Int\n\n    init(ann: Ann) {\n        self.ann = ann\n        pay = 3000\n    }\n}"
        let refused = try await refusals(given)
        #expect(
            refused == [
                "`let ann: Ann`: stored property 'ann' needs an initial value",
                "`var pay: Int`: stored property 'pay' needs an initial value",
                "`init(ann: Ann)` is never called",
            ], "\(refused)")
        #expect(
            try await refusals("actor Bob {\n    var pay = 3000\n\n    init() {}\n}") == ["`init()` is never called"])
        // Called on the type, Swift says so itself.
        let onType =
            "actor Bob {\n    func ask() async throws -> Bool {\n        try await Ann.approveRaise(200)\n    }\n}"
        #expect(
            try await refusals(onType) == [
                "`approveRaise` in `try await Ann.approveRaise(200)`: type 'Ann' has no member 'approveRaise'"
            ])
    }

    /// An object's own type is made with its id, as every object is, as a distributed actor is
    /// with its actor system: `Person(id:)` reaches another, and there's no `Person()`.
    @Test
    func itsOwnTypeIsMadeWithAnId() async throws {
        func refusals(_ code: String) async throws -> [String] {
            await ScriptInstance.problems(in: try Script(code: code, type: "Person")).map(\.message)
        }
        #expect(
            try await refusals(
                "actor Person {\n    var friend: Person? = nil\n\n    func meet() {\n        friend = Person(id: \"bob\")\n    }\n}"
            ).isEmpty)
        #expect(
            try await refusals(
                "actor Person {\n    var friend: Person? = nil\n\n    func meet() {\n        friend = Person()\n    }\n}"
            ) == [
                "missing argument for parameter 'id' in call"
            ])
        // One it writes is `init(id: String)`, and it runs with the object's id.
        let named = try await ScriptInstance.starts(
            try Script(
                code: "actor Person {\n    var name: String\n\n    init(id: String) {\n        name = id\n    }\n}",
                type: "Person"),
            as: ObjectIdentity(rawValue: "ann"))
        #expect(named["name"] == "ann")
        await #expect(throws: CodeProblem.self) {
            try await ScriptInstance.starts(
                try Script(
                    code: "actor Person {\n    var name: String\n\n    init() {\n        name = \"Ann\"\n    }\n}",
                    type: "Person"),
                as: ObjectIdentity(rawValue: "ann"))
        }
    }

    /// A stored property without a value is said of the property, as Swift says it, with how the
    /// object it holds is named: not of the `init(id:)` the object is given.
    @Test
    func aPropertyWithoutAValueIsSaidOfTheProperty() async throws {
        let uses = Uses(
            interface: ModuleInterface(
                name: Uses.module,
                source: "actor Website {\n    init(id: String)\n    @Event func buttonPressed(label: String)\n}"),
            objects: [ObjectIdentity(rawValue: "website"): "Website"])
        let code =
            "actor PressCounter {\n    var presses = 0\n    @Subscribed var website: Website\n\n    func onButtonPressed(label: String) {\n        presses += 1\n    }\n}"
        #expect(
            await ScriptInstance.problems(in: try Script(code: code, type: "PressCounter", uses: uses)).map(\.message)
                == [
                    "stored property 'website' needs an initial value"
                ])
    }

    /// What another object holds is read as another actor's property is in Swift, awaited: all
    /// but what's `private`, which is its own.
    @Test
    func anotherObjectsPropertiesAreReadUnlessPrivate() async throws {
        let ann = try Script(code: "actor Ann {\n    var budget = 1000\n    private var notes = \"\"\n}", type: "Ann")
            .spec(description: nil)
        let interface = Uses.interface(of: [Uses.Object(description: ann, publishes: true)])
        #expect(interface.source.contains("var budget: Int { get async throws }"), "\(interface.source)")
        #expect(!interface.source.contains("notes"), "\(interface.source)")
        let uses = Uses(interface: interface, objects: [ObjectIdentity(rawValue: "ann"): "Ann"])
        let bob =
            "actor Bob {\n    let ann = Ann(id: \"ann\")\n\n    func left() async throws -> Int {\n        try await ann.budget\n    }\n}"
        #expect(await ScriptInstance.problems(in: try Script(code: bob, type: "Bob", uses: uses)).isEmpty)
    }

    /// A built-in object's values are the Swift types they are: the writer is shown them as
    /// Swift declares them, the code is checked against them, what it publishes is read, and its
    /// values cross both ways as those types.
    @Test(.timeLimit(.minutes(2)))
    func anotherObjectsValuesAreTheirSwiftTypes() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shop, _ in
            try await withDynamicNode(joining: shop, store: store) { node in
                let player = try await Player(actorSystem: node)
                let board = try await Board(actorSystem: node)
                let session = ObjectSession(
                    actorSystem: node, objectCatalog: await ObjectCatalog(actorSystem: node), scopes: [.shared])
                try await eventually { (try await session.list().arrayValue?.count ?? 0) >= 2 }

                let others = await session.others(except: "Bridge")
                let shown = others.declarations.joined(separator: "\n")
                #expect(shown.contains("playing: Track?"))
                #expect(shown.contains("onTrackChanged(track: Track?)"))
                #expect(shown.contains("show(card: Card)"))
                #expect(
                    others.uses.interface.source.contains(
                        "struct Track: Codable {\n    var title: String\n    var artist: String?\n}"))
                #expect(others.uses.interface.source.contains("case row(items: [Piece])"))
                // The writer is told the values in words, never as declarations to copy.
                let words = others.uses.valuesInWords.joined(separator: "\n")
                #expect(
                    words.contains(
                        "- Track: a track, as a player plays it.\n  Fields:\n    title: String\n    artist: String?"))
                #expect(
                    words.contains("- Card: what a board shows. One of:\n    piece(Piece)\n    row(items: [Piece])"))
                #expect(!words.contains("struct"))
                // A built-in object's card is its spec.
                guard case .markdown(let card) = try await session.card(try await session.id(written: "player")) else { return }
                #expect(card.contains("takes:\n- 'play(track: Track) async throws'"))
                #expect(card.contains("publishes:\n- 'playing: Track? { get async throws }'"))
                #expect(card.contains("announces:\n- 'trackChanged(track: Track?)'"))

                let code = """
                    actor Bridge {
                        @Subscribed var player = Player(id: "player")
                        let board = Board(id: "board")
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
                let refused = await ScriptInstance.problems(
                    in: try Script(code: unawaited, type: "Bridge", uses: others.uses))
                #expect(
                    refused.map { $0.written(in: unawaited) } == [
                        "`player.playing` in `let now = player.playing`: expression is 'async' but is not marked with 'await'",
                        "`player.playing` in `let now = player.playing`: property access can throw, but it is not marked with 'try' and the error is not handled",
                    ])
                let script = try Script(code: code, type: "Bridge", uses: others.uses)
                #expect(await ScriptInstance.problems(in: script).isEmpty)

                let objects = try await DynamicObjects.resolve(on: node, scope: .shared)
                let bridge = try await DynamicObjects.resolve(on: node, scope: .shared).held(
                    try await objects.create(name: "Bridge", spec: .new(script)))
                try await eventually { try await bridge.read(property: "shown") == "" }
                try await Task.sleep(for: .seconds(2))
                try await player.play(Track(title: "Song", artist: nil))
                try await eventually { try await bridge.read(property: "shown") == "Song" }
                #expect(try await board.card == .row(items: [.text(words: "Song"), .button(label: "Next")]))
                // A struct it holds is journaled as `Codable` writes it.
                #expect(try await bridge.read(property: "last") == ["title": "Song"])
                // What it holds reads back, the object it follows as that object's handle.
                #expect(try await session.values(try await session.id(written: "bridge")).contains("player: player"))
            }
        }
    }

    /// A followed object's events are handled by its follower's functions named like them: none
    /// handled, or one taking other values, is refused, at its code.
    @Test
    func followingIsCheckedAgainstTheEvents() async throws {
        let shop = Uses(
            interface: ModuleInterface(
                name: Uses.module,
                source: "actor Shop {\n    init(id: String)\n    @Event func refundRequested(order: Int)\n}"),
            objects: [ObjectIdentity(rawValue: "shop"): "Shop"])
        for (code, refusal) in [
            (
                "actor Manager {\n    @Subscribed var shop = Shop(id: \"shop\")\n    func refund(order: Int) {}\n}",
                "no function handles the events of shop: onRefundRequested(order: Int)"
            ),
            (
                "actor Manager {\n    @Subscribed var shop = Shop(id: \"shop\")\n    func onRefundRequested(id: Int) {}\n}",
                "the event of shop calls onRefundRequested(order: Int)"
            ),
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
                let session = ObjectSession(
                    actorSystem: node, objectCatalog: await ObjectCatalog(actorSystem: node), scopes: [.shared])
                let others = await session.others(except: "Bob")
                let bob = """
                    actor Bob {
                        private(set) var pay = 3000

                        @Subscribed
                        private var ann = Ann(id: "ann")

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
                    _ = try await DynamicObjects.resolve(on: node, scope: .shared).held(identity).describe()
                }
                try await eventually { (try? await session.yourObjects())?.map(\.name) == ["ann", "bob"] }
                #expect(try await session.yourObjects().map(\.name) == ["ann", "bob"])
                // Using one offers its tools, never another `edit_object` for it alone, which would
                // stand in for the one that changes any of them.
                let bobTools = try await session.usingPage(of: try await session.id(written: "bob")).links.map(\.name)
                #expect(!bobTools.contains("edit_object"))
                let root = try await ObjectTools(session: session).tools().map(\.name)
                #expect(root.contains("edit_object"))
            }
        }
    }

    /// Code names an object by its id, `Type(id:)`: the same id is the same object, whoever names
    /// it and whenever, made the first time; it stays the same after a restart, and one of another
    /// type is refused. Making one by name that's there already says so.
    @Test(.timeLimit(.minutes(2)))
    func theSameIdIsTheSameObject() async throws {
        let store = MemoryEventStore()
        let counter =
            "actor Counter {\n    var count = 0\n\n    func add() -> Int {\n        count += 1\n        return count\n    }\n}"
        let drinks = """
            actor Drinks {
                private let tea = Counter(id: "tea")
                private let coffee = Counter(id: "coffee")

                func addTea() async throws -> Int {
                    try await tea.add()
                }

                func addCoffee() async throws -> Int {
                    try await coffee.add()
                }

                func add(to id: String) async throws -> Int {
                    try await Counter(id: id).add()
                }
            }
            """
        let counterUses = Uses(
            interface: ModuleInterface(
                name: Uses.module,
                source: "actor Counter {\n    init(id: String)\n    func add() async throws -> Int\n}"),
            objects: [:])
        try await withShopNodes(store: store) { shop, _ in
            let drinksID = try await withDynamicNode(joining: shop, store: store) { node in
                let objects = try await DynamicObjects.resolve(on: node, scope: .shared)
                _ = try await objects.create(name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))
                let drinksID = try await objects.create(
                    name: "Drinks", spec: .new(try Script(code: drinks, type: "Drinks", uses: counterUses)))
                let desk = try await objects.held(drinksID)
                #expect(try await desk.respond("addTea", arguments: [:]).reply == .integer(1))
                #expect(try await desk.respond("addTea", arguments: [:]).reply == .integer(2))
                #expect(try await desk.respond("addCoffee", arguments: [:]).reply == .integer(1))
                // A method naming `tea` reaches the same counter; a new id is a new one.
                #expect(try await desk.respond("add", arguments: ["to": "tea"]).reply == .integer(3))
                #expect(try await desk.respond("add", arguments: ["to": "juice"]).reply == .integer(1))
                #expect(try await desk.respond("add", arguments: ["to": "juice"]).reply == .integer(2))
                // An id of another type is refused.
                let refused = await #expect(throws: (any Error).self) {
                    _ = try await desk.respond("add", arguments: ["to": "drinks"])
                }
                #expect(
                    "\(refused.map { String(describing: $0) } ?? "")".contains(
                        "`drinks` is a `Drinks`, not a `Counter`."))
                // Making one by name that code made already says it's there.
                let taken = await #expect(throws: DynamicObjectsError.self) {
                    _ = try await objects.create(name: "tea", spec: .new(try Script(code: counter, type: "Counter")))
                }
                #expect(taken == .exists("tea", type: "Counter"))
                return drinksID
            }
            try await withDynamicNode(joining: shop, store: store) { node in
                let desk = try await DynamicObjects.resolve(on: node, scope: .shared).held(drinksID)
                #expect(try await desk.respond("addTea", arguments: [:]).reply == .integer(4))
                #expect(try await desk.respond("addCoffee", arguments: [:]).reply == .integer(2))
                #expect(try await desk.respond("add", arguments: ["to": "juice"]).reply == .integer(3))
            }
        }
    }

    /// An object is made on behalf of whoever's call made it, from any node, and so is one its
    /// code makes as it starts. Both keep it across a restart.
    @Test(.timeLimit(.minutes(2)))
    func anObjectKeepsWhoMadeIt() async throws {
        let store = MemoryEventStore()
        let ann = CallScope.person(UserID("ann"), in: GroupID(rawValue: "family"), as: .admin)
        let counter = "actor Counter {\n    var count = 0\n}"
        let drinks = "actor Drinks {\n    private let tea = Counter(id: \"tea\")\n}"
        let uses = Uses(
            interface: ModuleInterface(name: Uses.module, source: "actor Counter {\n    init(id: String)\n}"),
            objects: [:])
        try await withShopNodes(store: store) { shop, customers in
            let drinksID = try await withDynamicNode(joining: shop, store: store) { _ in
                // Made from a node that hosts no objects: the call carries Ann to the one that does.
                try await CallChain.$current.withValue(.start(ann)) {
                    let objects = try await DynamicObjects.resolve(on: customers, scope: .shared)
                    _ = try await objects.create(
                        name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))
                    return try await objects.create(
                        name: "Drinks", spec: .new(try Script(code: drinks, type: "Drinks", uses: uses)))
                }
            }
            try await withDynamicNode(joining: shop, store: store) { node in
                let objects = try await DynamicObjects.resolve(on: node, scope: .shared)
                #expect(try await objects.held(drinksID).maker == ann)
                let tea = try #require(try await Self.heldIdentity("tea", of: drinksID, on: node))
                let made = try await DynamicObject.resolve(
                    on: node, nature: ObjectNature(identity: tea, scope: .shared))
                #expect(try await made.maker == ann)
            }
        }
    }

    /// What an object holds comes back after a restart as it was: the object it made is the same
    /// one, restored, not made again.
    @Test(.timeLimit(.minutes(2)))
    func aRestartRestoresTheObjectsItHolds() async throws {
        let store = MemoryEventStore()
        let counter =
            "actor Counter {\n    var count = 0\n\n    func add() -> Int {\n        count += 1\n        return count\n    }\n}"
        let drinks =
            "actor Drinks {\n    private let tea = Counter(id: \"tea\")\n\n    func addTea() async throws -> Int {\n        try await tea.add()\n    }\n}"
        let uses = Uses(
            interface: ModuleInterface(
                name: Uses.module,
                source: "actor Counter {\n    init(id: String)\n    func add() async throws -> Int\n}"), objects: [:])
        try await withShopNodes(store: store) { shop, _ in
            let (drinksID, tea) = try await withDynamicNode(joining: shop, store: store) { node in
                let objects = try await DynamicObjects.resolve(on: node, scope: .shared)
                _ = try await objects.create(name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))
                let drinksID = try await objects.create(
                    name: "Drinks", spec: .new(try Script(code: drinks, type: "Drinks", uses: uses)))
                return (drinksID, try await Self.heldIdentity("tea", of: drinksID, on: node))
            }
            try await withDynamicNode(joining: shop, store: store) { node in
                let restored = try await Self.heldIdentity("tea", of: drinksID, on: node)
                #expect(restored != nil && restored == tea)
            }
        }
    }

    /// Which object the object `identity` holds in `field`.
    private static func heldIdentity(_ field: String, of identity: ObjectIdentity, on node: ClusterSystem) async throws
        -> ObjectIdentity?
    {
        let holder = try await DynamicObjects.resolve(on: node, scope: .shared).held(identity)
        guard case .actor(let reference, _)? = ObjectReference(try await holder.read(property: field)) else {
            return nil
        }
        return DynamicObject.identity(of: try reference.actorID(using: node))
    }

    /// A reference is parsed once, in each of its forms, and written back as it came; data that
    /// only looks like one stays data.
    @Test
    func referencesReadAndWriteAsTheyCame() throws {
        let forms: [(JSONValue, ObjectReference)] = [
            (["object": "ann"], .named("ann", type: nil)),
            (["object": "ann", "type": "Clerk"], .named("ann", type: "Clerk")),
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
            (
                "actor Shop {\n    var total = 0\n    func pay(_ amount: Int) {\n        charge(amount)\n    }\n    private func charge(_ amount: Int) throws {\n        total += amount\n    }\n}",
                ["`charge(amount)`: call can throw, but it is not marked with 'try' and the error is not handled"]
            ),
            (
                "actor Shop {\n    var total = 0\n    func pay(_ amount: Int) {\n        do {\n            try charge(amount)\n        } catch {}\n    }\n    private func charge(_ amount: Int) throws {\n        total += amount\n    }\n}",
                []
            ),
            (
                "actor Shop {\n    func pay() {\n        settle()\n    }\n    private func settle() async {}\n}",
                ["`settle()`: 'async' call in a function that does not support concurrency"]
            ),
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
            (
                "actor Shop {\n    var last: Int?\n    func big() -> Bool {\n        if let last, last > 10 {\n            return true\n        }\n        return false\n    }\n}",
                []
            ),
            (
                "actor Shop {\n    var last: Int?\n    func big() -> Bool {\n        guard let amount = last, amount > 10 else {\n            return false\n        }\n        return amount > 100\n    }\n}",
                []
            ),
            (
                "actor Shop {\n    var last: Int?\n    func paid() -> Bool {\n        if last {\n            return true\n        }\n        return false\n    }\n}",
                ["`last` in `if last {`: optional type 'Int?' cannot be used as a boolean; test for '!= nil' instead"]
            ),
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
                        name: Uses.module,
                        source:
                            "struct Order: Codable {\n    var status: Status\n}\n\nenum Status: String, Codable {\n    case placed\n}"
                    ),
                    objects: [:])
                let code = """
                    actor Shop {
                        var mood: Mood = .calm

                        func order() -> Order {
                            mood = .busy
                            return Order(status: .placed)
                        }
                    }

                    enum Mood: Codable {
                        case calm, busy
                    }
                    """
                let script = try Script(code: code, type: "Shop", uses: uses)
                #expect(await ScriptInstance.problems(in: script).isEmpty)
                let identity = try await objects.create(name: "Shop", spec: .new(script))
                let made = try await DynamicObjects.resolve(on: node, scope: .shared).held(identity)
                #expect(try await made.respond("order", arguments: [:]).reply == ["status": "placed"])
            }
        }
    }

    /// A reference of one type to an actor of another fails, whatever it's called with: it never
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

    /// An object conforming to a protocol another declares is given to it, and called through it;
    /// one that doesn't take the protocol's messages fails the call back to its caller.
    @Test(.timeLimit(.minutes(2)))
    func anObjectIsCalledThroughAProtocol() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shop, _ in
            try await withDynamicNode(joining: shop, store: store) { node in
                let objects = try await DynamicObjects.resolve(on: node, scope: .shared)
                let session = ObjectSession(
                    actorSystem: node, objectCatalog: await ObjectCatalog(actorSystem: node), scopes: [.shared])
                let desk = """
                    actor Desk {
                        protocol RefundManager {
                            func refundRequested(order: Int) async throws
                        }

                        var managers: [any RefundManager] = []

                        func startShift(manager: any RefundManager) {
                            managers.append(manager)
                        }

                        func refund(order: Int) async throws {
                            for manager in managers {
                                try await manager.refundRequested(order: order)
                            }
                        }
                    }
                    """
                let deskID = try await objects.create(name: "Desk", spec: .new(try Script(code: desk, type: "Desk")))
                let others = await session.others(except: "Ann")
                // Ann's writer is told what the protocol takes.
                let listed = others.declarations.joined(separator: "\n")
                #expect(
                    listed.contains("  Protocols:\n    Desk.RefundManager: refundRequested(order: Int) async throws"),
                    "\(listed)")
                let ann =
                    "actor Ann: Desk.RefundManager {\n    var handled: [Int] = []\n\n    func refundRequested(order: Int) async throws {\n        handled.append(order)\n    }\n}"
                let annScript = try Script(code: ann, type: "Ann", uses: others.uses)
                #expect(await ScriptInstance.problems(in: annScript).isEmpty)
                let annID = try await objects.create(name: "Ann", spec: .new(annScript))
                let counter = "actor Counter {\n    var count = 0\n}"
                let counterID = try await objects.create(
                    name: "Counter", spec: .new(try Script(code: counter, type: "Counter")))

                // Only Ann conforms: she's what the shift's argument offers.
                #expect(
                    await session.conforming(to: ObjectProtocolName(rawValue: "Desk.RefundManager")) == [try await session.id(written: "ann")])

                let deskObject = try await objects.held(deskID)
                let annObject = try await objects.held(annID)
                _ = try await deskObject.respond(
                    "startShift",
                    arguments: ["manager": try ObjectReference.actor(ActorReference(annObject), type: "Ann").json])
                _ = try await deskObject.respond("refund", arguments: ["order": 7])
                #expect(try await annObject.read(property: "handled") == [7])

                // One put on shift anyway, that doesn't take the message, fails the call.
                let counterObject = try await objects.held(counterID)
                _ = try await deskObject.respond(
                    "startShift",
                    arguments: [
                        "manager": try ObjectReference.actor(ActorReference(counterObject), type: "Counter").json
                    ])
                await #expect(throws: (any Error).self) {
                    try await deskObject.respond("refund", arguments: ["order": 8])
                }
            }
        }
    }

    /// An object named in a method, `Type(id:)`, can be kept, and called later.
    @Test(.timeLimit(.minutes(2)))
    func anObjectNamedInAMethodCanBeKept() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shop, _ in
            try await withDynamicNode(joining: shop, store: store) { node in
                let objects = try await DynamicObjects.resolve(on: node, scope: .shared)
                let ann =
                    "actor Ann {\n    var budget = 1000\n\n    func approve(amount: Int) -> Bool {\n        amount < 100\n    }\n}"
                _ = try await objects.create(name: "Ann", spec: .new(try Script(code: ann, type: "Ann")))
                let session = ObjectSession(
                    actorSystem: node, objectCatalog: await ObjectCatalog(actorSystem: node), scopes: [.shared])
                let others = await session.others(except: "Bob")
                let bob = """
                    actor Bob {
                        private var manager: Ann?

                        func hire() {
                            manager = Ann(id: "ann")
                        }

                        func ask(amount: Int) async throws -> Bool {
                            guard let manager else { return false }
                            return try await manager.approve(amount: amount)
                        }

                        func budget() async throws -> Int {
                            try await Ann(id: "ann").budget
                        }
                    }
                    """
                // What's kept is still another object: unwrapped, it's called as one.
                let unawaited = bob.replacingOccurrences(of: "try await manager.approve", with: "manager.approve")
                let refused = await ScriptInstance.problems(
                    in: try Script(code: unawaited, type: "Bob", uses: others.uses))
                #expect(
                    refused.map { $0.written(in: unawaited) } == [
                        "`manager.approve(amount: amount)` in `return manager.approve(amount: amount)`: expression is 'async' but is not marked with 'await'",
                        "`manager.approve(amount: amount)` in `return manager.approve(amount: amount)`: call can throw, but it is not marked with 'try' and the error is not handled",
                    ])
                let bobScript = try Script(code: bob, type: "Bob", uses: others.uses)
                #expect(await ScriptInstance.problems(in: bobScript).isEmpty)
                let bobID = try await objects.create(name: "Bob", spec: .new(bobScript))
                let bobObject = try await DynamicObjects.resolve(on: node, scope: .shared).held(bobID)
                _ = try await bobObject.respond("hire", arguments: [:])
                #expect(try await bobObject.respond("ask", arguments: ["amount": 50]).reply == .bool(true))
                // What another object holds is read, as another actor's property is.
                #expect(try await bobObject.respond("budget", arguments: [:]).reply == .integer(1000))
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
                let code =
                    "actor Ann {\n    func loop() async throws -> Int {\n        return try await Ann(id: \"ann\").loop()\n    }\n}"
                let identity = try await objects.create(name: "Ann", spec: .new(try Script(code: code, type: "Ann")))
                let ann = try await DynamicObjects.resolve(on: node, scope: .shared).held(identity)

                await #expect(throws: (any Error).self) { try await ann.respond("loop", arguments: [:]) }
                guard case .failing(let failure) = try await ann.health else {
                    Issue.record("Ann's health isn't failing")
                    return
                }
                #expect(
                    failure.problem.hasPrefix("calls went 65 deep: ann → ann → "), "\(failure.problem)")
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

/// A node for the shop and warehouse, and one for customers, both outliving any dynamic node.
private func withShopNodes<Result>(
    store: MemoryEventStore,
    _ body: (_ shop: ClusterSystem, _ customers: ClusterSystem) async throws -> Result
) async throws -> Result {
    try await withClusterSystem("shop", store: store, hostsVirtualActors: false) { shop in
        try await withClusterSystem("customers", store: store, joining: shop, hostsVirtualActors: false) {
            customers in
            try await body(shop, customers)
        }
    }
}

/// A node hosting dynamic objects, joined to `other`, for as long as `body` runs.
private func withDynamicNode<Result>(
    joining other: ClusterSystem,
    store: MemoryEventStore,
    _ body: (ClusterSystem) async throws -> Result
) async throws -> Result {
    try await withClusterSystem("dynamic", store: store, joining: other, hostsVirtualActors: true, body)
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
            for envelope in envelopes { continuation.yield(envelope) }
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

/// A player, a built-in object: what it plays, published, and each change announced.
@Discoverable(events: TrackChanged.self)
distributed actor Player {
    typealias ActorSystem = ClusterSystem
    private var current: Track?

    init(actorSystem: ActorSystem) async throws {
        self.actorSystem = actorSystem
        await actorSystem.receptionist.checkIn(
            try DiscoverableObject.resolve(id: id, using: actorSystem), with: ObjectScope.shared.receptionistKey)
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

/// A board, a built-in object: it shows a card.
@Discoverable
distributed actor Board {
    typealias ActorSystem = ClusterSystem
    private var shown: Card?

    init(actorSystem: ActorSystem) async throws {
        self.actorSystem = actorSystem
        await actorSystem.receptionist.checkIn(
            try DiscoverableObject.resolve(id: id, using: actorSystem), with: ObjectScope.shared.receptionistKey)
    }

    /// What it shows.
    public distributed var card: Card? { shown }

    /// Shows `card`.
    public distributed func show(card: Card) {
        shown = card
    }
}
