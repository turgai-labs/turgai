import DiscoverableActors
import DistributedCluster
import Foundation

/// A pretend shop, for trying out objects: orders come in and customers ask for refunds.
@Discoverable(events: OrderPlaced.self, RefundRequested.self)
public distributed actor Shop {
    public typealias ActorSystem = ClusterSystem

    private var placed: [ShopOrder] = []
    /// Managers on duty, in the order they started their shift.
    private var managersOnDuty: [(identity: ObjectIdentity, manager: DynamicObject)] = []
    private var nextManager = 0
    /// Refunds waiting for a manager's decision, by order number.
    private var openRefunds: [Int: OpenRefund] = [:]

    public init(actorSystem: ActorSystem, scope: ObjectScope = .shared) async throws {
        self.actorSystem = actorSystem
        let object = try DiscoverableObject.resolve(id: self.id, using: actorSystem)
        await actorSystem.receptionist.checkIn(object, with: scope.receptionistKey)
    }

    /// The shop's orders, oldest first.
    public distributed var orders: [ShopOrder] { placed }

    /// The managers on duty, who decide on refunds.
    public distributed var managers: [DynamicObject] { managersOnDuty.map(\.manager) }

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

    /// A manager starts their shift: refund requests go to the managers on duty, in turn,
    /// starting with any that were waiting for one.
    /// - Parameter manager: The manager: the shop sends it refundRequested(order: Int, total: Double)
    ///   for each refund it's to decide, and it answers the shop with refundApproved(order:) or
    ///   refundDenied(order:).
    public distributed func startShift(manager: DynamicObject) async throws {
        let identity = try await manager.identity
        guard !managersOnDuty.contains(where: { $0.identity == identity }) else { return }
        managersOnDuty.append((identity, manager))
        for number in openRefunds.filter({ $0.value.handler == .waitingForAManager }).keys.sorted() {
            assign(number)
        }
    }

    /// A manager ends their shift: the refunds they hadn't decided go to another manager on
    /// duty, or wait for one.
    /// - Parameter manager: The manager, matched by identity.
    public distributed func endShift(manager: DynamicObject) async throws {
        let identity = try await manager.identity
        managersOnDuty.removeAll { $0.identity == identity }
        for number in openRefunds.filter({ $0.value.handler == .manager(identity) }).keys.sorted() {
            assign(number)
        }
    }

    /// A customer asks for their money back for an order. A manager on duty decides, and the
    /// shop returns without waiting for the decision.
    /// - Parameters:
    ///   - number: The order's number.
    ///   - replyTo: The customer, to tell how it ended: an object taking ``RefundCustomer``'s
    ///     messages.
    public distributed func requestRefund(number: Int, replyTo: DiscoverableObject) async throws -> ShopOrder {
        let order = try update(number) { order in
            guard order.status == .placed else { throw ShopError.notRefundable(number, order.status) }
            order.status = .refundRequested
        }
        openRefunds[number] = OpenRefund(customer: replyTo, handler: .waitingForAManager)
        await announce(RefundRequested(order: order))
        assign(number)
        return order
    }

    /// A manager approved a refund: it's paid out, and the customer is told.
    /// - Parameter order: The order's number.
    public distributed func refundApproved(order: Int) async throws -> ShopOrder {
        let decided = try update(order) { decided in
            guard decided.status == .refundRequested else { throw ShopError.notRefundable(order, decided.status) }
            decided.status = .refunded
        }
        try await openRefunds.removeValue(forKey: order)?.customer.send(RefundCustomer.refunded(number: order))
        return decided
    }

    /// A manager refused a refund: the order stands, and the customer is told.
    /// - Parameter order: The order's number.
    public distributed func refundDenied(order: Int) async throws -> ShopOrder {
        let decided = try update(order) { decided in
            guard decided.status == .refundRequested else { throw ShopError.notRefundable(order, decided.status) }
            decided.status = .refundDenied
        }
        try await openRefunds.removeValue(forKey: order)?.customer.send(RefundCustomer.refundDenied(number: order))
        return decided
    }

    /// Hands an open refund to the next manager on duty, or leaves it waiting for one.
    private func assign(_ number: Int) {
        guard var refund = openRefunds[number], let order = placed.first(where: { $0.number == number }) else { return }
        guard !managersOnDuty.isEmpty else {
            refund.handler = .waitingForAManager
            openRefunds[number] = refund
            return
        }
        let (identity, manager) = managersOnDuty[nextManager % managersOnDuty.count]
        nextManager += 1
        refund.handler = .manager(identity)
        openRefunds[number] = refund
        Task { await send(order, to: manager) }
    }

    /// Passes a refund request to a manager, without waiting for the decision. Like any
    /// message, it can't fail the request: if the manager can't be reached, that's logged.
    private func send(_ order: ShopOrder, to manager: DynamicObject) async {
        do {
            let total = NSDecimalNumber(decimal: order.amount).doubleValue
            try await manager.send(RefundManager.refundRequested(order: order.number, total: total))
        } catch {
            actorSystem.log.warning(
                "Couldn't pass a refund request to a manager",
                metadata: ["order": "\(order.number)", "manager": "\(manager)", "error": "\(error)"])
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

/// What the shop sends a manager on duty.
@Describable
public enum RefundManager: Messages {
    /// A customer asked for their money back for `order`, by its number, which cost `total`.
    case refundRequested(order: Int, total: Double)
}

/// What the shop tells a customer about their refund.
@Describable
public enum RefundCustomer: Messages {
    case refunded(number: Int)
    case refundDenied(number: Int)
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
    /// The refund was refused; the order stands.
    case refundDenied
}

/// A refund waiting for a manager's decision.
private struct OpenRefund {
    /// Who asked, to tell how it ended.
    let customer: DiscoverableObject
    var handler: Handler

    enum Handler: Equatable {
        case manager(ObjectIdentity)
        case waitingForAManager
    }
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
