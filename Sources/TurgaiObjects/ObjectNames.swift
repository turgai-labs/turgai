import DiscoverableActors
import DistributedCluster
import TurgaiDomain
import VirtualActors

/// Objects by name, the way models and behaviors refer to them: `shop` or `Shop` for the shop,
/// `refund-manager-ann` or `Refund manager Ann` for Ann.
public enum ObjectNames {
    /// A handle for a title: kebab case, such as `reminder-list` for ReminderList or
    /// `refund-manager-ann` for "Refund manager Ann".
    public static func handle(for title: String) -> String {
        var handle = ""
        for character in title {
            if character.isLetter || character.isNumber {
                if character.isUppercase, !handle.isEmpty, handle.last != "-" { handle.append("-") }
                handle.append(Character(character.lowercased()))
            } else if !handle.isEmpty, handle.last != "-" {
                handle.append("-")
            }
        }
        while handle.last == "-" { handle.removeLast() }
        return handle.isEmpty ? "object" : handle
    }

    /// The Swift type an object named `name` is to other objects' code: `RefundManagerAnn` for
    /// "Refund manager Ann". Its own code declares its actor with it too.
    public static func typeName(of name: String) -> String {
        let type = handle(for: name).split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return type.first?.isLetter == true ? type : "Object" + type
    }

    /// The object named `name` in `space`, besides those made there by name, if there's one: one
    /// offered there, an agent or an installed built-in object, by the name its id gives it. Two of
    /// one name are refused: neither is the one meant. A virtual actor is one object however many
    /// nodes offered it; this node's reference is the one used.
    public static func object(named name: String, in space: SpaceID, using system: ClusterSystem) async throws
        -> (object: DiscoverableObject, description: ObjectDescription)?
    {
        var offered: [VirtualActorID: DiscoverableObject] = [:]
        for object in await system.receptionist.lookup(.virtualObjects(in: space)) {
            guard let virtual = object.id.virtualActorID, ObjectID.virtual(virtual).name == handle(for: name) else {
                continue
            }
            if offered[virtual] == nil || object.id.node == system.cluster.node { offered[virtual] = object }
        }
        let found = Array(offered.values)
        guard found.count < 2 else { throw DynamicObjectError.severalNamed(name) }
        guard let object = found.first else { return nil }
        return (object, try await object.describe())
    }
}
