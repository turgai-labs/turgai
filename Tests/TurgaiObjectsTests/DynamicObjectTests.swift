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

/// The refund manager, filled in the way a model fills in the typed objects_define.
let refundManagerTyped: JSONValue = {
    func name(_ name: String) -> JSONValue { ["type": "name", "value": .string(name)] }
    func number(_ number: Double) -> JSONValue { ["type": "number", "value": .number(number)] }
    let parameters: JSONValue = [["name": "number", "type": "integer"], ["name": "total", "type": "number"]]
    let approve: JSONValue = [
        "type": "send", "message": "refundApproved", "to": name("shop"), "arguments": [["name": "number", "value": name("number")]],
    ]
    return [
        "fields": [
            ["name": "approveBelow", "start": number(50)], ["name": "reviewing", "start": ["type": "list", "value": []]],
            ["name": "approved", "start": number(0)],
        ],
        "receive": [
            [
                "on": "refundRequested", "parameters": parameters,
                "when": [["left": name("total"), "comparison": "lessThan", "right": name("approveBelow")]],
                "actions": [approve, ["type": "add", "value": number(1), "to": "approved"]],
            ],
            [
                "on": "refundRequested", "parameters": parameters,
                "actions": [["type": "append", "value": name("number"), "to": "reviewing"]],
            ],
            [
                "on": "approve", "parameters": [["name": "number", "type": "integer"]],
                "when": [["left": name("reviewing"), "comparison": "contains", "right": name("number")]],
                "actions": [
                    ["type": "remove", "value": name("number"), "from": "reviewing"], approve,
                    ["type": "add", "value": number(1), "to": "approved"],
                ],
            ],
            ["on": "pending", "actions": [["type": "reply", "value": name("reviewing")]]],
        ],
    ]
}()

let salaryProtocols: YAML = """
    salary answers:
      - raiseApproved(amount: number)
      - raiseDenied(reason: string)
    salary review:
      - raiseRequested(amount: number, worker: salary answers)
    """

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
                try await demo.shop.startShift(manager: ann)
                try await demo.shop.startShift(manager: bob)

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

    /// The manager and the worker: protocols given with the manager's spec, the worker talking to
    /// it through a field, and a raise asked for, approved, and paid.
    @Test(.timeLimit(.minutes(2)))
    func aWorkerAsksItsManagerForARaise() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shopNode, _ in
            try await withDynamicNode(joining: shopNode, store: store) { _ in
                let objects = try await Maker(on: shopNode)
                let ann = try await objects.create(
                    name: "Ann", spec: try .yaml(YAML(BehaviorTests.manager), protocols: salaryProtocols))
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
                    #expect(String(describing: error).contains("sends `raiseRequested` to Bob, which doesn't take it."))
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
                _ = try await bob.invoke("refundRequested", arguments: ["number": 9, "total": 80])

                let counting = BehaviorTests.refundManager + "\n  - on: howMany()\n    reply: approved\n"
                try await objects.update(object: ann, change: try .spec(yaml: YAML(counting)))
                #expect(try await ann.describe().actions["howMany"] != nil)
                #expect(try await bob.describe().actions["howMany"] != nil)
                #expect(try await bob.read(property: "approveBelow") == 20)
                #expect(try await bob.invoke("pending", arguments: nil) == [9])
                _ = (demo, node)
            }
        }
    }

    /// A send to an object by name is checked against what that object takes, the mistake a
    /// small model made: passing `total` where the shop takes `number`.
    @Test(.timeLimit(.minutes(1)))
    func sendsAreCheckedAgainstWhatTheirObjectTakes() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shopNode, _ in
            let demo = try await DemoObjects(actorSystem: shopNode)
            try await withDynamicNode(joining: shopNode, store: store) { _ in
                let objects = try await Maker(on: shopNode)
                var wrong = BehaviorTests.refundManager
                let first = try #require(wrong.range(of: "send: shop.refundApproved(number)"))
                wrong.replaceSubrange(first, with: "send: shop.refundApproved(total)")
                #expect(wrong != BehaviorTests.refundManager)
                do {
                    _ = try await objects.create(name: "Ann", spec: try .yaml(YAML(wrong)))
                    Issue.record("A send with the wrong argument was accepted")
                } catch {
                    #expect(String(describing: error).contains("sends Shop `refundApproved` with `total`, but it's `refundApproved(number: integer)`"))
                }
                do {
                    _ = try await objects.create(
                        name: "X", spec: try .yaml("receive:\n  - on: go()\n    do:\n      - send: nobody.hello()"))
                    Issue.record("A send to nobody was accepted")
                } catch {
                    #expect(String(describing: error).contains("there's no object named nobody"))
                }
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
                _ = try await ann.invoke("refundRequested", arguments: ["number": 7, "total": 90])
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

    /// What a model does through its tools: create is a typed tool, `sameAs` takes a handle, and
    /// each object brings tools of its own.
    @Test(.timeLimit(.minutes(2)))
    func aModelCreatesThroughItsTools() async throws {
        let store = MemoryEventStore()
        try await withShopNodes(store: store) { shopNode, sessionNode in
            let demo = try await DemoObjects(actorSystem: shopNode)
            try await withDynamicNode(joining: shopNode, store: store) { _ in
                let session = ObjectSession(actorSystem: sessionNode, scopes: [.shared])
                try await eventually { (try? await session.describe("shop")) != nil }
                let tools = ObjectTools(session: session).tools
                #expect(
                    Set(tools.map(\.name)).isSuperset(of: ["objects_define", "objects_list", "objects_remove", "objects_guide"]))
                #expect(!tools.contains { $0.name == "objects_create" || $0.name == "objects_update" })
                // objects_define comes with the guide, so requests that don't make objects don't carry it.
                #expect(!ObjectTools(session: session).everyTurn.contains { $0.name == "objects_define" })
                #expect(await ObjectDefiningTools(session: session).tools().isEmpty)
                let guide = try #require(tools.first { $0.name == "objects_guide" })
                _ = try await AnyTool(guide).runOutput(generatedContent: GeneratedContent(properties: [:]), authority: FullAuthority())
                #expect(await ObjectDefiningTools(session: session).tools().map(\.name) == ["objects_define"])
                let create = try #require(tools.first { $0.name == "objects_define" })
                func run(_ arguments: JSONValue) async throws -> String {
                    try await AnyTool(create).runOutput(
                        generatedContent: try GeneratedContent(json: try json(arguments)), authority: FullAuthority()
                    ).textRepresentation
                }

                #expect(
                    try await run(["name": "Ann", "spec": refundManagerTyped]) == "ann")
                try await eventually { await ObjectNames.object(named: "ann", in: [.shared], using: sessionNode) != nil }
                #expect(
                    try await run(["name": "Bob", "sameAs": "ann", "start": [["name": "approveBelow", "start": ["type": "number", "value": 20]]]]) == "bob")
                // A spec it can't use: the error says what's wrong, and where to read how it's written.
                let wrong = try await AnyTool(create).outcome(
                    generatedContent: try GeneratedContent(
                        json: try json(["name": "Carol", "spec": ["fields": [], "receive": []]])),
                    authority: FullAuthority())
                #expect(wrong.failureKind != nil)
                #expect(wrong.output.textRepresentation.contains("`receive` is empty"))
                _ = try await session.invoke("shop", action: "startShift", arguments: "manager: ann")
                #expect(try await session.read("shop", property: "managers") == ["ann"])
                let mine = await session.actionTools().map(\.name)
                #expect(mine.contains("ann_approve"))
                #expect(mine.contains("bob_pending"))
                _ = demo
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

    func update(object: DynamicObject, change: Change) async throws {
        try await directory.update(try await object.identity, change: change)
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
