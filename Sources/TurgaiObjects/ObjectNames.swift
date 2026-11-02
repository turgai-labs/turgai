import DiscoverableActors
import DistributedCluster
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

    /// The object named `name` among those checked in, if one is: a virtual actor by its id, the
    /// one of its kind by its type. Two of one name are refused: neither is the one meant. A virtual
    /// actor is one object however many nodes checked in a reference to it; this node's own is the
    /// one used. A virtual actor checked in by its id is only asked what it is once it's the one.
    public static func object(named name: String, using system: ClusterSystem) async throws
        -> (object: DiscoverableObject, description: ObjectDescription)?
    {
        var references: [VirtualActorID: DiscoverableObject] = [:]
        var actors: [DiscoverableObject] = []
        var described: [ClusterSystem.ActorID: ObjectDescription] = [:]
        func keep(_ object: DiscoverableObject, as virtual: VirtualActorID) {
            if references[virtual] == nil || object.id.node == system.cluster.node { references[virtual] = object }
        }
        for object in await system.receptionist.lookup(.virtualObjects) {
            guard let virtual = object.id.virtualActorID, ObjectID.virtual(virtual).name == handle(for: name) else {
                continue
            }
            keep(object, as: virtual)
        }
        for object in await system.receptionist.lookup(.objects) {
            guard let description = try? await object.describe() else { continue }
            if let virtual = object.id.virtualActorID {
                guard ObjectID.virtual(virtual).name == handle(for: name) else { continue }
                keep(object, as: virtual)
            } else {
                guard ObjectID.actor(object.id, type: description.type).name == handle(for: name) else { continue }
                actors.append(object)
            }
            described[object.id] = description
        }
        let found = Array(references.values) + actors
        guard found.count < 2 else { throw DynamicObjectError.severalNamed(name) }
        guard let object = found.first else { return nil }
        if let description = described[object.id] { return (object, description) }
        return (object, try await object.describe())
    }
}
