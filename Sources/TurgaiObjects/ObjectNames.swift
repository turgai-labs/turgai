import DiscoverableActors
import DistributedCluster
import TurgaiDomain
import VirtualActors

/// Objects by name, the way models and behaviors refer to them: `shop` or `Shop` for the shop,
/// `refund-manager-ann` or `Refund manager Ann` for Ann.
public enum ObjectNames {
    /// A handle for a title: kebab case, such as `reminder-list` for ReminderList,
    /// `weather-api` for WeatherAPI, or `refund-manager-ann` for "Refund manager Ann".
    public static func handle(for title: String) -> String {
        let handle = words(of: title).map { $0.lowercased() }.joined(separator: "-")
        return handle.isEmpty ? "object" : handle
    }

    /// The Swift type an object named `name` is to other objects' code: `RefundManagerAnn` for
    /// "Refund manager Ann", `WeatherAPI` for WeatherAPI. Its own code declares its actor with it too.
    public static func typeName(of name: String) -> String {
        let type = words(of: name).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return type.first?.isLetter == true ? type : "Object" + type
    }

    /// The words of a title, as written: apart where it's spaced or punctuated, and where its
    /// camel case starts a word, an acronym being one, as `API` is in WeatherAPIClient.
    private static func words(of title: String) -> [String] {
        var words: [String] = []
        var word = ""
        let characters = Array(title)
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !word.isEmpty { words.append(word) }
                word = ""
                continue
            }
            if character.isUppercase, let last = word.last {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                let startsWord = !last.isUppercase || next?.isLowercase == true
                if startsWord {
                    words.append(word)
                    word = ""
                }
            }
            word.append(character)
        }
        if !word.isEmpty { words.append(word) }
        return words
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
