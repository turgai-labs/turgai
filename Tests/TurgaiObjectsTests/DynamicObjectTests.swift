import DiscoverableActors
import DistributedCluster
import Foundation
import Testing
@testable import TurgaiObjects

/// The vision's order tracker, as a spec: state and actions, and a reference to the
/// warehouse it tells about refunds.
let orderTrackerJSON = #"""
{
  "id": "order-tracker",
  "title": "Order tracker",
  "description": "Tracks the shop's orders, and tells the warehouse about refunds.",
  "properties": {
    "orders": { "description": "Orders seen so far.", "schema": { "type": "array" }, "initial": [] },
    "warehouse": { "description": "Where refunds go.", "schema": { "x-actor-reference": true }, "initial": null }
  },
  "actions": {
    "recordOrder": {
      "description": "Record a new order.",
      "input": { "type": "object", "properties": { "event": {} }, "required": ["event"] },
      "steps": [ { "append": "orders", "value": { "from": "arguments.event.order" } } ]
    },
    "refundRequested": {
      "description": "Tell the warehouse a refund is coming.",
      "input": { "type": "object", "properties": { "event": {} }, "required": ["event"] },
      "steps": [ { "call": "warehouse", "action": "refundApproved", "arguments": { "order": { "from": "arguments.event.order" } } } ]
    },
    "summary": { "description": "The orders seen so far.", "steps": [ { "return": { "from": "properties.orders" } } ] }
  }
}
"""#

@Suite(.serialized)
struct DynamicObjectTests {
    @Test
    func specsAreReadFromJSON() throws {
        let spec = try JSONDecoder().decode(ObjectSpec.self, from: Data(orderTrackerJSON.utf8))
        #expect(spec.title == "Order tracker")
        #expect(
            spec.actions["refundRequested"]?.steps
                == [.call(property: "warehouse", action: "refundApproved", arguments: ["order": .from(["arguments", "event", "order"])])])
        let again = try JSONDecoder().decode(ObjectSpec.self, from: JSONEncoder().encode(spec))
        #expect(again == spec)
    }

    @Test
    func specsOnlyUseDeclaredProperties() {
        let spec = ObjectSpec(id: "x", title: "X", actions: ["bump": .init(steps: [.set(property: "count", to: .literal(1))])])
        #expect(throws: ObjectSpecError.unknownProperty("count", in: "bump")) { try spec.validate() }
    }

    @Test(.timeLimit(.minutes(1)))
    func theOrderTrackerHearsTheShopAndTellsTheWarehouse() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let demo = try await DemoObjects(actorSystem: objectsNode)
            let spec = try JSONDecoder().decode(ObjectSpec.self, from: Data(orderTrackerJSON.utf8))
            let tracker = try await DynamicObject(
                actorSystem: sessionNode, spec: spec,
                values: ["warehouse": .reference(to: demo.warehouse)],
                scope: .shared
            )

            // Wired from outside, as its creator would.
            let listener = try ActorReference(tracker)
            try await demo.shop.subscribeEvent("OrderPlaced", listener: listener, action: "recordOrder")
            try await demo.shop.subscribeEvent("RefundRequested", listener: listener, action: "refundRequested")

            _ = try await demo.shop.placeOrder(item: "Lamp", amount: 40)
            _ = try await demo.shop.placeOrder(item: "Chair", amount: 90)
            guard case .array(let orders) = try await tracker.read(property: "orders") else {
                Issue.record("orders isn't a list")
                return
            }
            #expect(orders.compactMap { $0["item"] } == ["Lamp", "Chair"])

            _ = try await demo.shop.requestRefund(number: 2)
            #expect(try await demo.warehouse.notes.map(\.order) == [2])

            // It's an object like any other: described, and its actions run by name.
            let description = try await tracker.describe()
            #expect(description.title == "Order tracker")
            #expect(Set(description.actions.keys) == ["recordOrder", "refundRequested", "summary"])
            #expect(try await tracker.invoke("summary", arguments: nil) == .array(orders))
            await #expect(throws: DiscoveryError.unexpectedArgument("x")) {
                try await tracker.invoke("summary", arguments: ["x": 1])
            }
        }
    }
}
