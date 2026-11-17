import DiscoverableActors
import Distributed
import DistributedCluster
import TurgaiCalls
import TurgaiDomain
import VirtualActors

/// Which object something is, as the system knows it, and as models and people are shown it: the
/// system's own id, and nothing else.
public enum ObjectID: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    /// A virtual actor, by its id: the same wherever and whenever it runs.
    case virtual(VirtualActorID)
    /// Any other actor, by its id: which it is while it lives. With the type it's found by when
    /// it's the one of its kind checked in here.
    case actor(ClusterSystem.ActorID, type: String?)

    /// What it's called: the last part of a virtual actor's id; the type of the one of its kind
    /// checked in here. One an action returned, of a type there can be many of, is
    /// called by its id.
    public var name: String {
        switch self {
        case .virtual(let id): id.rawValue.split(separator: "/").last.map(String.init) ?? id.rawValue
        case .actor(_, let type?): ObjectNames.handle(for: type)
        case .actor(let id, nil): "\(id.node)\(id.path)"
        }
    }

    /// How it's written: its name, which reads back as it.
    public var description: String { name }

    /// In the order they're written in, as they're listed.
    public static func < (lhs: ObjectID, rhs: ObjectID) -> Bool {
        lhs.description < rhs.description
    }
}

extension ObjectID {
    /// The object the actor a call reached is.
    public init(_ actor: CallActor) {
        switch actor {
        case .virtual(let id): self = .virtual(id)
        case .actor(let id): self = .actor(id, type: nil)
        }
    }

    /// The actor it is, as a call reaches it.
    public var callActor: CallActor {
        switch self {
        case .virtual(let id): .virtual(id)
        case .actor(let id, _): .actor(id)
        }
    }
}

/// A catalog entry ready to show to a model.
public struct ObjectEntry: Codable, Sendable {
    public let id: ObjectID
    public let object: DiscoverableObject
    /// The type it is of.
    public let type: String
    public let description: String?
    /// Each action with its arguments, such as `play(query)`.
    public let actions: [String]
    /// What the object announces, such as `RefundRequested`.
    public let events: [String]

    public init(
        id: ObjectID,
        object: DiscoverableObject,
        type: String,
        description: String?,
        actions: [String],
        events: [String] = []
    ) {
        self.id = id
        self.object = object
        self.type = type
        self.description = description
        self.actions = actions
        self.events = events
    }
}

/// How a space's objects are listed to a model: each action as a short signature.
public enum ObjectCatalog {
    /// An action with its argument names, such as `add(title, notes?)`, so a model
    /// can call it without describing the object first.
    public static func signature(_ key: String, input: JSONValue?) -> String {
        let name = ActionKeys.baseName(of: key)
        guard case .object(let properties)? = input?["properties"], !properties.isEmpty else { return "\(name)()" }
        let required: [String] =
            if case .array(let names)? = input?["required"] {
                names.compactMap { if case .string(let name) = $0 { name } else { nil } }
            } else { [] }
        // As Swift declares it, with its label, when its schema keeps it.
        func declared(_ name: String, _ schema: JSONValue) -> String {
            let type = schema.swiftType.map { ": \($0)" } ?? ""
            guard case .string(let label)? = schema[ObjectShape.Message.labelKey], label != name else {
                return name + type
            }
            return "\(label) \(name)\(type)"
        }
        let written =
            required.compactMap { name in properties[name].map { declared(name, $0) } }
            + properties.keys.filter { !required.contains($0) }.sorted().map { name in
                "\(name)" + (properties[name]!.swiftType.map { ": \($0)?" } ?? "?")
            }
        return "\(name)(\(written.joined(separator: ", ")))"
    }
}
