import DiscoverableActors
import DistributedCluster

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
    /// actor checked in by its id is only asked what it is once it's the one.
    public static func object(named name: String, using system: ClusterSystem) async throws
        -> (object: DiscoverableObject, description: ObjectDescription)?
    {
        var found: [DiscoverableObject] = []
        var described: [ClusterSystem.ActorID: ObjectDescription] = [:]
        for object in await system.receptionist.lookup(.virtualObjects)
        where object.id.virtualActorID.map({ ObjectID.virtual($0).name }) == handle(for: name) {
            found.append(object)
        }
        for object in await system.receptionist.lookup(.objects) {
            guard let description = try? await object.describe() else { continue }
            let id = object.id.virtualActorID.map(ObjectID.virtual) ?? .actor(object.id, type: description.type)
            if id.name == handle(for: name) {
                found.append(object)
                described[object.id] = description
            }
        }
        guard found.count < 2 else { throw DynamicObjectError.severalNamed(name) }
        guard let object = found.first else { return nil }
        if let description = described[object.id] { return (object, description) }
        return (object, try await object.describe())
    }
}
