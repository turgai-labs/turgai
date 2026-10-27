import DiscoverableActors
import DistributedCluster
import Foundation

/// A pretend warehouse, for trying out objects: it takes instructions about orders.
@Discoverable
public distributed actor Warehouse {
    public typealias ActorSystem = ClusterSystem

    private var received: [WarehouseNote] = []

    public init(actorSystem: ActorSystem) async throws {
        self.actorSystem = actorSystem
        let object = try DiscoverableObject.resolve(id: self.id, using: actorSystem)
        await actorSystem.receptionist.checkIn(object, with: .objects)
    }

    /// What the warehouse has been told, oldest first.
    public distributed var notes: [WarehouseNote] { received }

    /// Tell the warehouse a refund was approved, so it expects the item back.
    /// - Parameter order: The refunded order.
    public distributed func refundApproved(order: ShopOrder) {
        received.append(WarehouseNote(order: order.number, item: order.item, instruction: .expectReturn, at: Date()))
    }
}

/// One instruction the warehouse received.
@Describable
public struct WarehouseNote: Codable, Sendable, Equatable {
    /// The order it's about.
    public var order: Int
    /// The order's item.
    public var item: String
    /// What to do.
    public var instruction: WarehouseInstruction
    /// When it arrived.
    public var at: Date
}

/// What the warehouse is asked to do.
@Describable
public enum WarehouseInstruction: String, Codable, Sendable, CaseIterable {
    /// A refund was approved: the item is coming back.
    case expectReturn
}

/// Read by everyone and written by no one, until whoever runs its node is known.
extension Warehouse: AccessControlled {
    public func access(for chain: CallChain) -> ObjectAccess { .readByEveryone }
}
