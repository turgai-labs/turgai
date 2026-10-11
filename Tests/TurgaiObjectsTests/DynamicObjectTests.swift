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
    /// Ann and Bob share one behavior, each with its own limit, both on duty at the shop.
    @Test(.timeLimit(.minutes(2)))
    func annAndBobShareABehaviorAtTheShop() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shopNode, customerNode in
            let demo = try await DemoObjects(actorSystem: shopNode)
            let customer = Customer(actorSystem: customerNode)
            let replyTo = try DiscoverableObject.resolve(id: customer.id, using: shopNode)
            _ = try await demo.shop.placeOrder(item: "Lamp", amount: 40)
            _ = try await demo.shop.placeOrder(item: "Chair", amount: 30)

            try await withDynamicNode(joining: shopNode, store: store) { _ in
                let objects = try await Maker(on: shopNode)
                let ann = try await objects.create(
                    name: "Refund manager Ann", spec: try .yaml(YAML(BehaviorTests.refundManager)))
                let bob = try await objects.create(name: "Refund manager Bob", spec: .sameAs(ann), start: "approveBelow: 20")
                try await demo.shop.startShift(manager: Wanted(ann))
                try await demo.shop.startShift(manager: Wanted(bob))

                // Order 1 goes to Ann, under her limit: approved straight away.
                _ = try await demo.shop.requestRefund(number: 1, replyTo: replyTo)
                try await eventually { try await customer.news == ["refunded 1"] }
                // Order 2 goes to Bob, over his: he keeps it for review until he's told to approve.
                _ = try await demo.shop.requestRefund(number: 2, replyTo: replyTo)
                try await eventually { try await bob.read(property: "reviewing") == [2] }
                _ = try await bob.invoke("approve", arguments: ["number": 2])
                try await eventually { try await customer.news == ["refunded 1", "refunded 2"] }
                #expect(try await ann.read(property: "approved") == 1)
                #expect(try await bob.read(property: "approveBelow") == 20)
            }
        }
    }

    /// The manager and the worker: Ann asks for an object like Bob before he exists, Bob talks to
    /// her through a field, and a raise is asked for, approved, and paid. A change to Ann that
    /// Bob's spec would break is refused.
    @Test(.timeLimit(.minutes(2)))
    func aWorkerAsksItsManagerForARaise() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shopNode, _ in
            try await withDynamicNode(joining: shopNode, store: store) { _ in
                let objects = try await Maker(on: shopNode)
                let ann = try await objects.create(
                    name: "Ann", spec: try .yaml(YAML(BehaviorTests.manager)))
                try await eventually { await ObjectNames.object(named: "ann", in: [.shared], using: shopNode) != nil }
                let bob = try await objects.create(name: "Bob", spec: try .yaml(YAML(BehaviorTests.worker)))

                _ = try await bob.invoke("askForRaise", arguments: ["amount": 200])
                try await eventually { try await bob.invoke("salary", arguments: nil) == 3200 }
                #expect(try await ann.read(property: "remaining") == 800)
                #expect(try await bob.read(property: "lastAnswer") == "approved")

                // A worker whose manager is Bob: Bob doesn't take raiseRequested.
                do {
                    _ = try await objects.create(
                        name: "Carol",
                        spec: try .yaml(YAML(BehaviorTests.worker.replacingOccurrences(of: "{object: Ann}", with: "{object: Bob}"))))
                    Issue.record("Bob was accepted as a manager")
                } catch {
                    #expect(String(describing: error).contains("sends `raiseRequested` to `Bob`, which doesn't take it."))
                }

                // Ann no longer taking raiseRequested would break Bob, who sends it to her.
                do {
                    try await objects.update(object: ann, spec: try Behavior.Written(yaml: "receive:\n  - on: hello()"))
                    Issue.record("A change that breaks Bob was accepted")
                } catch {
                    #expect(String(describing: error).contains("This breaks the spec of Bob"))
                }
            }
        }
    }

    /// A new spec changes every object sharing it, each keeping its own values.
    @Test(.timeLimit(.minutes(2)))
    func aNewSpecChangesEveryObjectSharingIt() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shopNode, _ in
            let demo = try await DemoObjects(actorSystem: shopNode)
            try await withDynamicNode(joining: shopNode, store: store) { node in
                let objects = try await Maker(on: shopNode)
                let ann = try await objects.create(
                    name: "Refund manager Ann", spec: try .yaml(YAML(BehaviorTests.refundManager)))
                let bob = try await objects.create(name: "Refund manager Bob", spec: .sameAs(ann), start: "approveBelow: 20")
                _ = try await bob.invoke("refundRequested", arguments: ["order": 9, "total": 80])

                let counting = BehaviorTests.refundManager + "\n  - on: howMany()\n    reply: approved\n"
                try await objects.update(object: ann, spec: try Behavior.Written(yaml: YAML(counting)))
                #expect(try await ann.describe().actions["howMany"] != nil)
                #expect(try await bob.describe().actions["howMany"] != nil)
                #expect(try await bob.read(property: "approveBelow") == 20)
                #expect(try await bob.invoke("pending", arguments: nil) == [9])
                _ = (demo, node)
            }
        }
    }

    static let counter = """
        fields:
          count: 0
        receive:
          - on: add()
            do:
              - add: 1 to count
          - on: howMany()
            reply: count
        """

    /// A kind is a behavior with no object: objects made the same as it share it and change with
    /// it, and a parameter like it is checked against its messages.
    @Test(.timeLimit(.minutes(2)))
    func aKindIsABehaviorWithNoObject() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shopNode, _ in
            let demo = try await DemoObjects(actorSystem: shopNode)
            try await withDynamicNode(joining: shopNode, store: store) { _ in
                let objects = try await Maker(on: shopNode)
                try await objects.directory.defineKind("counter", spec: try Behavior.Written(yaml: YAML(Self.counter)))
                let coffee = try await objects.create(name: "Coffee", spec: .kind("counter"))
                let tea = try await objects.create(name: "Tea", spec: .kind("counter"))
                _ = try await tea.invoke("add", arguments: nil)
                _ = try await tea.invoke("add", arguments: nil)
                #expect(try await tea.invoke("howMany", arguments: nil) == 2)
                #expect(try await coffee.invoke("howMany", arguments: nil) == 0)

                let resetting = Self.counter + "\n  - on: reset()\n    do:\n      - set: count to 0\n"
                try await objects.directory.defineKind("counter", spec: try Behavior.Written(yaml: YAML(resetting)))
                try await eventually { try await coffee.describe().actions["reset"] != nil }
                #expect(try await tea.read(property: "count") == 2)

                await #expect(throws: DynamicObjectsError.nameTaken("Counter")) {
                    _ = try await objects.create(name: "Counter", spec: .kind("counter"))
                }
                // A parameter like the kind takes its messages, and only those.
                let tally = "receive:\n  - on: count(c: counter)\n    do:\n      - send: c.add()"
                _ = try await objects.create(name: "Tally", spec: try .yaml(YAML(tally)))
                do {
                    _ = try await objects.create(
                        name: "Wrong", spec: try .yaml(YAML("receive:\n  - on: count(c: counter)\n    do:\n      - send: c.subtract()")))
                    Issue.record("A send the kind doesn't take was accepted")
                } catch {
                    #expect(String(describing: error).contains("subtract"))
                }
                // Changing the kind so Tally's send breaks is refused.
                do {
                    try await objects.directory.defineKind(
                        "counter", spec: try Behavior.Written(yaml: YAML("receive:\n  - on: howMany()\n    reply: 0")))
                    Issue.record("A change that breaks Tally was accepted")
                } catch {
                    #expect(String(describing: error).contains("This breaks the spec of Tally"))
                }
                _ = demo
            }
        }
    }

    /// A send to an object by name is checked against what that object takes, the mistake a
    /// small model made: passing `total` where the shop takes `order`.
    @Test(.timeLimit(.minutes(1)))
    func sendsAreCheckedAgainstWhatTheirObjectTakes() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shopNode, _ in
            let demo = try await DemoObjects(actorSystem: shopNode)
            try await withDynamicNode(joining: shopNode, store: store) { _ in
                let objects = try await Maker(on: shopNode)
                var wrong = BehaviorTests.refundManager
                let first = try #require(wrong.range(of: "send: shop.refundApproved(order)"))
                wrong.replaceSubrange(first, with: "send: shop.refundApproved(total)")
                #expect(wrong != BehaviorTests.refundManager)
                do {
                    _ = try await objects.create(name: "Ann", spec: try .yaml(YAML(wrong)))
                    Issue.record("A send with the wrong argument was accepted")
                } catch {
                    #expect(String(describing: error).contains("sends Shop `refundApproved` with `total`, but it's `refundApproved(order: integer)`"))
                }
                // An object not defined yet: accepted, and checked when a message reaches it.
                _ = try await objects.create(
                    name: "X", spec: try .yaml("receive:\n  - on: go()\n    do:\n      - send: nobody.hello()"))
                _ = demo
            }
        }
    }

    /// An object comes back after its node restarts, findable, with its fields, running its
    /// behavior as its directory has it.
    @Test(.timeLimit(.minutes(2)))
    func anObjectKeepsItsFieldsAcrossARestart() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shopNode, _ in
            let demo = try await DemoObjects(actorSystem: shopNode)
            let identity = try await withDynamicNode(joining: shopNode, store: store) { _ in
                let objects = try await Maker(on: shopNode)
                let ann = try await objects.create(
                    name: "Refund manager Ann", spec: try .yaml(YAML(BehaviorTests.refundManager)))
                _ = try await ann.invoke("refundRequested", arguments: ["order": 7, "total": 90])
                return try await ann.identity
            }
            try await withDynamicNode(joining: shopNode, store: store) { node in
                let ann = try await DynamicObject.resolve(on: node, identity: identity)
                #expect(try await ann.invoke("pending", arguments: nil) == [7])
                try await eventually { await ObjectNames.object(named: "refund-manager-ann", in: [.shared], using: node) != nil }
            }
            _ = demo
        }
    }

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

    /// What a model does through its tools, driven the way an agent's session drives them. It
    /// starts with list, search and create. Creating makes the object at once, in the runtime, and
    /// links its define tools, which change it as they're called; what it does can be used right
    /// away. Editing an object offers the same define tools on it.
    @Test(.timeLimit(.minutes(2)))
    func aModelMakesAndEditsObjects() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shopNode, sessionNode in
            let demo = try await DemoObjects(actorSystem: shopNode)
            try await withDynamicNode(joining: shopNode, store: store) { _ in
                // One catalog for the node, as the app has.
                let catalog = await ObjectCatalog(actorSystem: sessionNode)
                let session = ObjectSession(actorSystem: sessionNode, objectCatalog: catalog, scopes: [.shared])
                try await eventually { (try? await session.describe("shop")) != nil }
                var agentSession = AgentSession()
                agentSession.offer(TurnTools(tools: try await ObjectTools(session: session).tools(), pages: session))
                // Nothing to edit yet: editing is offered once there's something of yours.
                #expect(agentSession.schemas().map(\.name) == ["create_object", "list_objects", "search_objects"])
                var calls = 0
                func call(_ name: String, _ arguments: JSONValue = [:]) async throws -> ToolExecution {
                    calls += 1
                    let call = ToolCall(id: "\(calls)", name: name, arguments: try GeneratedContent(json: try json(arguments)))
                    return try await agentSession.execute(call)
                }
                /// What the model reads for a call: its result, then the page it landed on.
                func text(_ execution: ToolExecution) -> String {
                    ToolAnswer(result: execution.result, page: execution.page, tools: []).reading
                }
                func offered() -> [String] { agentSession.schemas().map(\.name) }
                func step(_ name: String, _ arguments: JSONValue) async throws -> ToolExecution {
                    let execution = try await call(name, arguments)
                    #expect(!execution.result.isError, "\(name): \(text(execution))")
                    return execution
                }
                /// The next turn begins: scopes carry over as they are; the root's tools are offered anew.
                func nextTurn() async throws {
                    _ = await agentSession.begin(TurnID())
                    agentSession.offer(TurnTools(tools: try await ObjectTools(session: session).tools(), pages: session))
                }
                /// Uses one of your objects: its using page, and its actions.
                func use(_ handle: String) async throws -> ToolExecution {
                    agentSession.offer(TurnTools(tools: try await ObjectTools(session: session).tools(), pages: session))
                    return try await step("use_object", ["object": .string(handle)])
                }

                // Each step says what's next, from the object as it is, and offers the object's
                // define tools, whose choices are its own.
                let planned = try await call("create_object", ["name": "Counter"])
                #expect(text(planned).contains("Next: add the data needed for this task with counter_add_data, then define its actions with counter_add_event."))
                #expect(offered().first == "counter")
                // It exists at once, in the runtime, holding and doing nothing.
                #expect(text(planned).hasPrefix("Created empty counter."))
                #expect(text(planned).contains("Object: counter\nCurrent values:\n- None defined.\nDefined actions and received events:\n- None defined."))
                try await eventually { await ObjectNames.object(named: "counter", in: [.shared], using: sessionNode) != nil }

                let held = try await step("counter_add_data", ["name": "cups", "kind": "number", "start": "0"])
                #expect(text(held).contains("Next: define the actions needed for this task with counter_add_event."))
                let eventTool = agentSession.tool(named: "counter_add_event")
                let event = try #require(eventTool)
                #expect(event.description == "Define an event and its steps. This saves the event; it does not run it.")
                let eventSchema = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(event.schema.parameters))
                #expect(eventSchema["$defs"]?["Step"]?["properties"]?["do"]?["enum"] == ["add to cups", "subtract from cups", "set cups", "clear cups", "get cups", "nothing", "tell shop refundApproved", "tell shop refundDenied"])

                // A name written as words is made one, and the result says what it does.
                let added = try await step(
                    "counter_add_event",
                    [
                        "event": "add cup", "takes": [["name": "amount", "type": "number"]],
                        "does": [["do": "add to cups", "value": ["argument": "amount"]]],
                    ])
                #expect(text(added).hasPrefix("addCup(amount: number):\n  → adds the given amount to cups"))
                #expect(text(added).contains("When the required actions are defined, call counter to open them."))
                // The making page stays focused on completing the definition. Opening the object
                // afterwards exposes its finished actions on a persistent tab.
                #expect(!offered().contains("counter_addCup"))
                let asked = try await step("counter_add_event", ["event": "how many", "does": [["do": "get cups"]]])
                #expect(text(asked).hasPrefix("howMany() -> integer:\n  → gives back cups"))
                // Clearing empties it; setting takes the new value when it's called.
                // A value on a step that takes none changes nothing, so it's let be.
                _ = try await step("counter_add_event", ["event": "peek", "does": [["do": "get cups", "value": 3]]])
                let cleared = try await step("counter_add_event", ["event": "reset", "does": [["do": "clear cups"]]])
                #expect(text(cleared).hasPrefix("reset():\n  → sets cups to 0"))
                let set = try await step(
                    "counter_add_event",
                    [
                        "event": "set count", "takes": [["name": "value", "type": "number"]],
                        "does": [["do": "set cups", "value": ["argument": "value"]]],
                    ])
                #expect(text(set).hasPrefix("setCount(value: number):\n  → sets cups to the given value"))
                // Opened, it shows what it holds now and offers what it does.
                let opened = try await use("counter")
                #expect(text(opened).hasPrefix("Opened counter."))
                #expect(text(opened).contains("Current values:\ncups: 0"))
                #expect(Set(offered()).isSuperset(of: ["counter_addCup", "counter_howMany", "counter_reset"]))
                #expect(!offered().contains("counter_values"))
                let firstCup = try await step("counter_addCup", ["amount": 1])
                #expect(text(firstCup).contains("Object state after the action:"))
                #expect(text(firstCup).contains("Current values:\ncups: 1"))
                #expect(text(firstCup).contains("Actions:\n- counter_addCup"))

                // The object page is a tab: the next turn refreshes it and keeps its current
                // actions callable without opening it again.
                try await nextTurn()
                #expect(offered().contains("counter_addCup"))
                #expect(Set(offered()).isSuperset(of: ["use_object", "edit_object", "remove_object"]))
                _ = try await step("counter_addCup", ["amount": 1])
                #expect(text(try await call("list_objects")).hasPrefix("Your objects: counter."))
                // Its page is where finding it leads: how to use it. Navigation links tolerate stale
                // arguments carried over from the tool that produced them.
                _ = try await call("search_objects", ["query": "counter"])
                let counter = try await call("counter", ["does": ["stale"]])
                // Its page shows what it holds now, and names the tools the model can use on it.
                #expect(text(counter).contains("Current values:\ncups: 2"))
                #expect(Set(offered()).isSuperset(of: ["counter_addCup", "counter_howMany", "counter_reset"]))
                #expect(text(counter).contains("- counter_addCup"))
                // Searching by what it does finds it.
                _ = try await call("search_objects", ["query": "how many"])
                #expect(offered().contains("counter"))

                let duplicate = try await call("create_object", ["name": "Counter"])
                #expect(text(duplicate) == "`counter` already exists.")
                _ = try await session.invoke("counter", action: "reset", arguments: nil)
                _ = try await session.invoke("counter", action: "addCup", arguments: #"{"amount": 1}"#)
                _ = try await session.invoke("counter", action: "addCup", arguments: #"{"amount": 1}"#)
                #expect(try await session.invoke("counter", action: "howMany", arguments: nil) == 2)

                // Editing changes it at once, a step at a time.
                let editing = try await call("edit_object", ["object": "counter"])
                #expect(text(editing).hasPrefix("Opened editing tools for counter."))
                _ = try await step(
                    "counter_add_event",
                    [
                        "event": "double", "takes": [["name": "amount", "type": "number"]],
                        "does": [["do": "add to cups", "value": ["argument": "amount"]]],
                    ])
                _ = try await session.invoke("counter", action: "double", arguments: #"{"amount": 2}"#)
                #expect(try await session.invoke("counter", action: "howMany", arguments: nil) == 4)

                // What an event is given, and a list.
                _ = try await call("create_object", ["name": "Shopping"])
                _ = try await step("shopping_add_data", ["name": "items", "kind": "list"])
                let shoppingTool = agentSession.tool(named: "shopping_add_event")
                let shoppingEvent = try #require(shoppingTool)
                let shoppingSchema = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(shoppingEvent.schema.parameters))
                #expect(shoppingSchema["$defs"]?["Step"]?["properties"]?["do"]?["enum"] == ["append to items", "remove from items", "set items", "clear items", "get items", "nothing", "tell shop refundApproved", "tell shop refundDenied"])
                _ = try await step(
                    "shopping_add_event",
                    [
                        "event": "addItem", "takes": [["name": "item", "type": "text"]],
                        "does": [["do": "append to items", "value": ["argument": "item"]]],
                    ])
                _ = try await use("shopping")
                _ = try await step("shopping_addItem", ["item": "milk"])
                #expect(try await session.read("shopping", property: "items") == ["milk"])
                _ = try await session.invoke("shopping", action: "addItem", arguments: #"{"item": "eggs"}"#)

                // A step that doesn't fit is refused, and the object stays as it was.
                _ = try await call("create_object", ["name": "Broken"])
                _ = try await step("broken_add_data", ["name": "count", "kind": "number", "start": "0"])
                #expect(try await call("broken_add_event", ["event": "x", "does": [["do": "add to missing"]]]).result.isError)
                #expect(
                    text(try await call("broken_add_event", ["event": "missing", "does": [["do": "add to count"]]]))
                        .contains("`add to count` needs `value`"))
                // Adding is by the amount the event is given.
                #expect(
                    text(
                        try await step(
                            "broken_add_event",
                            [
                                "event": "y", "takes": [["name": "amount", "type": "number"]],
                                "does": [["do": "add to count", "value": ["argument": "amount"]]],
                            ])
                    ).hasPrefix("y(amount: number):\n  → adds the given amount to count"))
                _ = try await step(
                    "broken_add_event",
                    [
                        "event": "add extra", "takes": [["name": "amount", "type": "number"]],
                        "does": [
                            ["do": "add to count", "value": ["argument": "amount"]],
                            ["do": "add to count", "value": 1],
                        ],
                    ])
                _ = try await session.invoke("broken", action: "addExtra", arguments: #"{"amount": 2}"#)
                #expect(try await session.read("broken", property: "count") == 3)

                // The same event and condition again replaces what it does.
                let replaced = try await step(
                    "counter_add_event",
                    [
                        "event": "double", "takes": [["name": "amount", "type": "number"]],
                        "does": [["do": "subtract from cups", "value": ["argument": "amount"]]],
                    ])
                #expect(text(replaced).hasPrefix("double(amount: number):\n  → subtracts the given amount from cups"))
                // An event taken out is gone.
                let removed = try await step("counter_remove_event", ["event": "double"])
                #expect(text(removed).hasPrefix("double is gone"))
                // Doing nothing is a choice too: the event is taken, and nothing changes.
                let idle = try await step("counter_add_event", ["event": "wave", "does": [["do": "nothing"]]])
                #expect(text(idle).hasPrefix("wave():\n  → nothing"))

                // An object made like one of yours does what it does, shared, and holds its own
                // values: only one of yours can be named, and changing the events of one changes both.
                agentSession.offer(TurnTools(tools: try await ObjectTools(session: session).tools(), pages: session))
                #expect(try await call("create_object_like", ["object": "dave", "name": "Carol"]).result.isError)
                let tea = try await step("create_object_like", ["object": "counter", "name": "Tea"])
                #expect(text(tea).hasPrefix("Made tea: it does what counter does, and holds its own values."))
                #expect(text(tea).contains("Shared definition with: Counter."))
                _ = try await step("tea_set_value", ["data": "cups", "value": "7"])
                #expect(try await session.read("tea", property: "cups") == 7)
                _ = try await step(
                    "tea_add_event",
                    [
                        "event": "sip", "takes": [["name": "amount", "type": "number"]],
                        "does": [["do": "subtract from cups", "value": ["argument": "amount"]]],
                    ])
                #expect(try await session.describe("counter")["actions"]?["sip"] != nil)
                #expect(text(try await call("list_objects")).hasPrefix("Your objects: broken, counter, shopping, tea."))
                #expect(try await session.read("shopping", property: "items") == ["milk", "eggs"])

                // Finding an object links to its first page, which links to its actions: those it
                // can take now. No object of yours is a manager, so startShift isn't one.
                _ = try await call("search_objects", ["query": "shop"])
                _ = try await call("shop")
                #expect(offered().contains("shop_placeOrder"))
                #expect(!offered().contains("shop_startShift"))

                // Its subject gone, what a scope links to has nothing to work on.
                _ = try await call("create_object", ["name": "Scratch"])
                _ = try await step("scratch_add_data", ["name": "n", "kind": "number", "start": "0"])
                agentSession.offer(TurnTools(tools: try await ObjectTools(session: session).tools(), pages: session))
                _ = try await step("remove_object", ["object": "scratch"])
                #expect(try await call("scratch_add_data", ["name": "m", "kind": "number"]).result.isError)
                #expect(!text(try await call("list_objects")).contains("scratch"))
                _ = demo
            }
        }
    }

    /// The shop wants managers that take `refundRequested(order, total)`. A model makes Ann with
    /// `ann_handle`, whose choices come from what the shop asks; copies her as Bob, with his own
    /// limit; and puts both on shift, choosing from the objects that fit.
    @Test(.timeLimit(.minutes(2)))
    func aModelMakesRefundManagersForTheShop() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shopNode, sessionNode in
            let demo = try await DemoObjects(actorSystem: shopNode)
            let customer = Customer(actorSystem: sessionNode)
            let replyTo = try DiscoverableObject.resolve(id: customer.id, using: shopNode)
            _ = try await demo.shop.placeOrder(item: "Lamp", amount: 40)
            _ = try await demo.shop.placeOrder(item: "Chair", amount: 30)
            try await withDynamicNode(joining: shopNode, store: store) { _ in
                let catalog = await ObjectCatalog(actorSystem: sessionNode)
                let session = ObjectSession(actorSystem: sessionNode, objectCatalog: catalog, scopes: [.shared])
                try await eventually { (try? await session.describe("shop")) != nil }
                var agentSession = AgentSession()
                var calls = 0
                func call(_ name: String, _ arguments: JSONValue = [:]) async throws -> ToolExecution {
                    calls += 1
                    let call = ToolCall(id: "\(calls)", name: name, arguments: try GeneratedContent(json: try json(arguments)))
                    return try await agentSession.execute(call)
                }
                func text(_ execution: ToolExecution) -> String {
                    ToolAnswer(result: execution.result, page: execution.page, tools: []).reading
                }
                func offered() -> [String] { agentSession.schemas().map(\.name) }
                func step(_ name: String, _ arguments: JSONValue) async throws -> ToolExecution {
                    let execution = try await call(name, arguments)
                    #expect(!execution.result.isError, "\(name): \(text(execution))")
                    return execution
                }
                func root() async throws {
                    agentSession.offer(TurnTools(tools: try await ObjectTools(session: session).tools(), pages: session))
                }
                func schema(_ name: String) throws -> JSONValue {
                    let found = agentSession.tool(named: name)
                    let tool = try #require(found)
                    return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(tool.schema.parameters))
                }

                // The shop says what it wants of a manager, and that none of yours fits yet: its
                // startShift can't be called.
                try await root()
                _ = try await step("search_objects", ["query": "shop"])
                let shop = try await step("shop", [:])
                #expect(text(shop).contains("Argument manager needs an object that takes refundRequested(order: integer, total: number); may answer refundApproved(order: integer) or refundDenied(order: integer). None of your created objects meets this requirement yet."))
                #expect(!offered().contains("shop_startShift"))

                // Ann: what she holds, then what she does with what the shop sends.
                try await root()
                let made = try await step("create_object", ["name": "Ann"])
                #expect(text(made).contains("Events other objects send:\n- shop sends refundRequested(order: integer, total: number) to its manager. The manager can reply with refundApproved(order: integer) or refundDenied(order: integer).\nAdd an event with ann_add_event only if ann needs to handle it for the current task."))
                _ = try await step("ann_add_data", ["name": "limit", "kind": "number", "start": "50"])
                _ = try await step("ann_add_data", ["name": "pending", "kind": "list"])
                _ = try await step("ann_add_data", ["name": "approved", "kind": "number", "start": "0"])
                // An event on what the shop sends: its parameters come from the shop's spec, and it
                // does its steps in order, as an Erlang clause's body.
                let event = try schema("ann_add_event")
                let approving = try await step(
                    "ann_add_event",
                    [
                        "event": "refundRequested", "if": ["argument": "total"], "is": "<=", "than": ["data": "limit"],
                        "does": [["do": "tell shop refundApproved"], ["do": "add to approved", "value": 1]],
                    ])
                #expect(text(approving).hasPrefix("refundRequested(order: integer, total: number):\n  if total <= limit → tells shop refundApproved(order: the given order), then adds 1 to approved\n  otherwise → nothing"))
                // Ann now takes what the shop sends a manager: her page says where she can go, and
                // offers it.
                #expect(text(approving).contains("You can pass ann as argument manager to shop_startShift."))
                #expect(offered().contains("shop_startShift"))
                // A message another object sends uses its own values: which one, `with` says.
                #expect(try await call("ann_add_event", ["event": "refundRequested", "does": [["do": "append to pending"]]]).result.isError)
                // Otherwise, the next clause: she keeps it.
                let keeping = try await step(
                    "ann_add_event",
                    ["event": "refundRequested", "does": [["do": "append to pending", "value": ["argument": "order"]]]])
                #expect(text(keeping).hasPrefix("refundRequested(order: integer, total: number):\n  if total <= limit → tells shop refundApproved(order: the given order), then adds 1 to approved\n  otherwise → appends the given order to pending"))

                // Values are typed: a list isn't a number to add, and a name must be the event's or
                // its data's. A number can be a number; `nothing` among other steps is left out.
                let wrongType = try await call(
                    "ann_add_event",
                    ["event": "refundRequested", "does": [["do": "add to approved", "value": ["data": "pending"]]]])
                #expect(text(wrongType).contains("`add to approved` takes a number, but `pending` is a list."))
                let unknown = try await call(
                    "ann_add_event",
                    ["event": "refundRequested", "does": [["do": "add to approved", "value": ["argument": "amount"]]]])
                #expect(text(unknown).contains("There is no argument `amount`. Choose one of: order, total."))
                let counting = try await step(
                    "ann_add_event",
                    ["event": "refundRequested", "if": ["argument": "total"], "is": ">", "than": 1000, "does": [["do": "nothing"], ["do": "add to approved", "value": 0]]])
                #expect(text(counting).contains("if total > 1000 → adds 0 to approved"))

                // Bob does what Ann does, with his own limit.
                try await root()
                _ = try await step("create_object_like", ["object": "ann", "name": "Bob"])
                let bob = try await step("bob_set_value", ["data": "limit", "value": "20"])
                #expect(!text(bob).contains("To take one"))

                // Now both fit, and they're the shop's choices.
                try await root()
                _ = try await step("search_objects", ["query": "shop"])
                _ = try await step("shop", [:])
                #expect(try schema("shop_startShift")["properties"]?["manager"]?["enum"] == ["ann", "bob"])
                _ = try await step("shop_startShift", ["manager": "ann"])
                _ = try await step("shop_startShift", ["manager": "bob"])

                // Order 1, 40, goes to Ann, within her limit: approved. Order 2, 30, goes to Bob,
                // over his: he keeps it.
                _ = try await demo.shop.requestRefund(number: 1, replyTo: replyTo)
                try await eventually { try await customer.news == ["refunded 1"] }
                _ = try await demo.shop.requestRefund(number: 2, replyTo: replyTo)
                try await eventually { try await session.read("bob", property: "pending") == [2] }
            }
        }
    }

    /// An object that doesn't take what the shop wants is refused at the shop's edge.
    @Test(.timeLimit(.minutes(2)))
    func theShopRefusesAManagerThatDoesNotFit() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shopNode, _ in
            let demo = try await DemoObjects(actorSystem: shopNode)
            try await withDynamicNode(joining: shopNode, store: store) { _ in
                let objects = try await Maker(on: shopNode)
                let counter = try await objects.create(name: "Counter", spec: .written(.empty))
                await #expect(throws: ObjectDoesNotFit.self) { try await demo.shop.startShift(manager: Wanted(counter)) }
                #expect(try await demo.shop.managers.isEmpty)
            }
        }
    }
}

/// Makes and changes objects the way the objects tool does, through the scope's directory.
private struct Maker {
    let directory: DynamicObjects
    let node: ClusterSystem

    init(on node: ClusterSystem) async throws {
        self.node = node
        self.directory = try await DynamicObjects.resolve(on: node, scope: .shared)
    }

    func create(name: String, spec: Spec, start: YAML? = nil) async throws -> DynamicObject {
        var values: [String: JSONValue] = [:]
        if case .object(let given)? = try start?.read() { values = given }
        let identity = try await directory.create(name: name, spec: spec, start: values)
        return try await DynamicObject.resolve(on: node, identity: identity)
    }

    func update(object: DynamicObject, spec: Behavior.Written) async throws {
        try await directory.update(try await object.identity, spec: spec)
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
