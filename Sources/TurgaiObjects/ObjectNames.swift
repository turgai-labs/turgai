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

    /// Whether `name` refers to the object titled `title`: its title, ignoring case, or its handle.
    public static func matches(_ name: String, title: String) -> Bool {
        title.lowercased() == name.lowercased() || handle(for: title) == handle(for: name)
    }

    /// The object named `name` among those checked in to `scopes`, if one is.
    public static func object(
        named name: String, in scopes: [ObjectScope], using system: ClusterSystem
    ) async -> (object: DiscoverableObject, description: ObjectDescription)? {
        for scope in scopes {
            for object in await system.receptionist.lookup(scope.receptionistKey) {
                guard let description = try? await object.describe(), matches(name, title: description.title) else {
                    continue
                }
                return (object, description)
            }
        }
        return nil
    }
}
