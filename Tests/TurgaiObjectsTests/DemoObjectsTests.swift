import DiscoverableActors
import DistributedCluster
import Foundation
import Testing
import TurgaiDomain

@testable import TurgaiApplication
@testable import TurgaiObjects

/// A customer, told how their refunds end.
@Discoverable
distributed actor Customer {
    typealias ActorSystem = ClusterSystem

    private var heard: [String] = []

    init(actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
    }

    /// What the customer was told, oldest first.
    public distributed var news: [String] { heard }

    /// Your refund was paid out.
    /// - Parameter number: The order's number.
    public distributed func refunded(number: Int) {
        heard.append("refunded \(number)")
    }

    /// Your refund was refused.
    /// - Parameter number: The order's number.
    public distributed func refundDenied(number: Int) {
        heard.append("refund denied \(number)")
    }
}

@Suite(.serialized, .asTheRuntime)
struct DemoObjectsTests {
    @Test
    func modelRunsTheRefundStoryByHand() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let shop = try await Shop(actorSystem: objectsNode)
            let warehouse = try await Warehouse(actorSystem: objectsNode)
            // The customer is an object the model sees too, to name as who the shop replies to.
            let customer = Customer(actorSystem: sessionNode)
            await sessionNode.receptionist.checkIn(
                try DiscoverableObject.resolve(id: customer.id, using: sessionNode),
                with: ObjectScope.shared.receptionistKey)
            let catalog = await ObjectCatalog(actorSystem: sessionNode)
            let session = ObjectSession(actorSystem: sessionNode, objectCatalog: catalog, scopes: [.shared])

            let roots = try await waitForRoots(3, in: session)
            guard case .array(let entries) = roots else {
                Issue.record("Expected roots, got \(roots)")
                return
            }
            #expect(Set(entries.compactMap { $0["object_id"] }) == ["customer", "shop", "warehouse"])

            // Today the model carries the story; step 2 lets the objects do it themselves.
            let order = try await session.invoke(
                try await session.id(written: "shop"), action: "placeOrder", arguments: #"{"item": "Lamp", "amount": 40}"#)
            #expect(order["status"] == "placed")
            let request = #"{"number": 1, "replyTo": "customer"}"#
            let requested = try await session.invoke(try await session.id(written: "shop"), action: "requestRefund", arguments: request)
            #expect(requested["status"] == "refundRequested")
            _ = try await session.invoke(
                try await session.id(written: "warehouse"), action: "refundApproved",
                arguments: try ObjectSession.text(["order": requested]))

            let notes = try await warehouse.notes
            #expect(notes.map(\.order) == [1])
            #expect(notes.map(\.instruction) == [.expectReturn])

            await #expect(throws: ObjectToolError.failed(ShopError.notRefundable(1, .refundRequested).description)) {
                try await session.invoke(try await session.id(written: "shop"), action: "requestRefund", arguments: request)
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

            // The objects page lists it, with what it announces.
            let page = try await session.open(ObjectAddress.objects.address)
            let lines = (page.output.textValue ?? "").split(separator: "\n").map(String.init)
            #expect(
                lines.contains {
                    $0.hasPrefix("- id: `shop`; type: `Shop` — ")
                        && $0.contains(". Takes ")
                        && $0.hasSuffix("; events: OrderPlaced, RefundRequested")
                }, "\(lines)")
            _ = shop
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aSubscriberOnAnotherNodeHearsRefundRequests() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let shop = try await Shop(actorSystem: objectsNode)
            let remoteShop = try DiscoverableObject.resolve(id: shop.id, using: sessionNode)

            let requests = try await remoteShop.subscribe(to: RefundRequested.self)
            _ = try await shop.placeOrder(item: "Lamp", amount: 40)
            _ = try await shop.placeOrder(item: "Chair", amount: 90)
            let customer = Customer(actorSystem: sessionNode)
            _ = try await shop.requestRefund(
                number: 2, replyTo: try DiscoverableObject.resolve(id: customer.id, using: objectsNode))

            for try await request in requests {
                #expect(request.order.number == 2)
                break
            }
            await requests.cancel()
        }
    }
}
