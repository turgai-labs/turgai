import DiscoverableActors
import DistributedCluster
import Foundation

/// A pretend shop, for trying out objects: orders come in and customers ask for refunds.
@Discoverable(events: OrderPlaced.self, RefundRequested.self)
public distributed actor Shop {
    public typealias ActorSystem = ClusterSystem

    private var placed: [ShopOrder] = []

    public init(actorSystem: ActorSystem, scope: ObjectScope = .shared) async throws {
        self.actorSystem = actorSystem
        let object = try DiscoverableObject.resolve(id: self.id, using: actorSystem)
        await actorSystem.receptionist.checkIn(object, with: scope.receptionistKey)
    }

    /// The shop's orders, oldest first.
    public distributed var orders: [ShopOrder] { placed }

    /// Take an order.
    /// - Parameters:
    ///   - item: What was bought.
    ///   - amount: What it cost.
    public distributed func placeOrder(item: String, amount: Decimal) async -> ShopOrder {
        let order = ShopOrder(number: placed.count + 1, item: item, amount: amount, status: .placed)
        placed.append(order)
        await announce(OrderPlaced(order: order))
        return order
    }

    /// A customer asks for their money back for an order.
    /// - Parameter number: The order's number.
    public distributed func requestRefund(number: Int) async throws -> ShopOrder {
        let order = try update(number) { order in
            guard order.status == .placed else { throw ShopError.notRefundable(number, order.status) }
            order.status = .refundRequested
        }
        await announce(RefundRequested(order: order))
        return order
    }

    /// Mark a requested refund as paid out.
    /// - Parameter number: The order's number.
    public distributed func refund(number: Int) throws -> ShopOrder {
        try update(number) { order in
            guard order.status == .refundRequested else { throw ShopError.notRefundable(number, order.status) }
            order.status = .refunded
        }
    }

    private func update(_ number: Int, _ change: (inout ShopOrder) throws -> Void) throws -> ShopOrder {
        guard let index = placed.firstIndex(where: { $0.number == number }) else {
            throw ShopError.unknownOrder(number)
        }
        try change(&placed[index])
        return placed[index]
    }
}

/// An order came in.
@Describable
public struct OrderPlaced: Codable, Sendable, Equatable {
    /// The new order.
    public var order: ShopOrder

    public init(order: ShopOrder) {
        self.order = order
    }
}

/// A customer asked for their money back.
@Describable
public struct RefundRequested: Codable, Sendable, Equatable {
    /// The order to refund.
    public var order: ShopOrder

    public init(order: ShopOrder) {
        self.order = order
    }
}

/// An order in the shop.
@Describable
public struct ShopOrder: Codable, Sendable, Equatable {
    /// The order's number, counting from 1.
    public var number: Int
    /// What was bought.
    public var item: String
    /// What it cost.
    public var amount: Decimal
    /// Where the order stands.
    public var status: ShopOrderStatus

    public init(number: Int, item: String, amount: Decimal, status: ShopOrderStatus) {
        self.number = number
        self.item = item
        self.amount = amount
        self.status = status
    }
}

/// Where an order stands.
@Describable
public enum ShopOrderStatus: String, Codable, Sendable, CaseIterable {
    /// Bought and not disputed.
    case placed
    /// The customer asked for their money back.
    case refundRequested
    /// The money went back to the customer.
    case refunded
}

public enum ShopError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case unknownOrder(Int)
    case notRefundable(Int, ShopOrderStatus)

    public var description: String {
        switch self {
        case .unknownOrder(let number): "There's no order \(number)."
        case .notRefundable(let number, let status): "Order \(number) is \(status.rawValue), so that refund step doesn't apply."
        }
    }
}
