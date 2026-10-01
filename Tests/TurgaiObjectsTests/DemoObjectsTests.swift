import DiscoverableActors
import DistributedCluster
import Foundation
import Testing
import TurgaiDomain
@testable import TurgaiApplication
@testable import TurgaiObjects

/// Hears the shop's refund requests, on the session's node.
@Discoverable
distributed actor RefundWatcher {
    typealias ActorSystem = ClusterSystem

    private var heard: [Int] = []

    /// Order numbers of the refunds requested, oldest first.
    public distributed var requests: [Int] { heard }

    /// A customer asked for their money back.
    public distributed func refundRequested(_ request: RefundRequested) {
        heard.append(request.order.number)
    }
}

@Suite(.serialized)
struct DemoObjectsTests {
    @Test
    func modelRunsTheRefundStoryByHand() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let shop = try await Shop(actorSystem: objectsNode)
            let warehouse = try await Warehouse(actorSystem: objectsNode)
            let catalog = await ObjectCatalog(actorSystem: sessionNode)
            let session = ObjectSession(actorSystem: sessionNode, objectCatalog: catalog, scopes: [.shared])

            let roots = try await waitForRoots(2, in: session)
            guard case .array(let entries) = roots else {
                Issue.record("Expected roots, got \(roots)")
                return
            }
            #expect(Set(entries.compactMap { $0["handle"] }) == ["shop", "warehouse"])

            // Today the model carries the story; step 2 lets the objects do it themselves.
            let order = try await session.invoke("shop", action: "placeOrder", arguments: #"{"item": "Lamp", "amount": 40}"#)
            #expect(order["status"] == "placed")
            let requested = try await session.invoke("shop", action: "requestRefund", arguments: "1")
            #expect(requested["status"] == "refundRequested")
            _ = try await session.invoke(
                "warehouse", action: "refundApproved",
                arguments: try ObjectSession.text(["order": requested]))

            let notes = try await warehouse.notes
            #expect(notes.map(\.order) == [1])
            #expect(notes.map(\.instruction) == [.expectReturn])

            await #expect(throws: ObjectToolError.failed(ShopError.notRefundable(1, .refundRequested).description)) {
                try await session.invoke("shop", action: "requestRefund", arguments: "1")
            }
            _ = (shop, catalog)
        }
    }

    @Test
    func theModelSeesWhatTheShopAnnounces() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let shop = try await Shop(actorSystem: objectsNode)
            let catalog = await ObjectCatalog(actorSystem: sessionNode)
            let session = ObjectSession(actorSystem: sessionNode, objectCatalog: catalog, scopes: [.shared])

            let roots = try await waitForRoots(1, in: session)
            guard case .array(let entries) = roots, let entry = entries.first else {
                Issue.record("Expected the shop, got \(roots)")
                return
            }
            #expect(entry["events"] == ["OrderPlaced", "RefundRequested"])

            guard let conversation = TurgaiDomain.ConversationID(stableKey: "web:ada") else {
                Issue.record("Invalid conversation ID")
                return
            }
            let lines = await ObjectSession.turnContext(
                actorSystem: sessionNode, objectCatalog: catalog, conversationID: conversation)
            #expect(lines.contains { $0.hasPrefix("- `shop`, Shop: ") && $0.hasSuffix("; events: OrderPlaced, RefundRequested") })
            _ = shop
        }
    }

    @Test
    func aListenerOnAnotherNodeHearsRefundRequests() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let shop = try await Shop(actorSystem: objectsNode)
            let watcher = RefundWatcher(actorSystem: sessionNode)
            let remoteShop = try DiscoverableObject.resolve(id: shop.id, using: sessionNode)

            try await remoteShop.subscribeEvent(
                "RefundRequested", listener: ActorReference(watcher), action: "refundRequested")
            _ = try await shop.placeOrder(item: "Lamp", amount: 40)
            _ = try await shop.placeOrder(item: "Chair", amount: 90)
            _ = try await shop.requestRefund(number: 2)

            #expect(try await watcher.requests == [2])
        }
    }
}
