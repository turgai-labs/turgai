import DiscoverableActors

/// Another object, as code, tools and the journal hold it: parsed once, where JSON comes in, and
/// written back as it came. A living actor is held by its ID, as an Erlang pid is; an object can
/// also be held by the name it's reached by, found at each use, as an Erlang registered name is.
public enum ObjectReference: Sendable, Equatable {
    /// A living actor, by its ID: what built-in objects send and take, `{"id": …}`, with the
    /// type it's of when whoever made the reference knew it: `{"id": …, "type": "Wallet"}`.
    case actor(ActorReference, type: String?)
    /// The object reached by this name, found at each use: `{"object": name}`, with the type it's
    /// of when whoever named it knew, as code knows the objects its module names. Written, a name
    /// doesn't say its type: `{"object": …, "type": …}` is a virtual actor.
    case named(String, type: String?)
    /// The object's own code passing itself on, which its object makes its own reference:
    /// `{"self": true}`.
    case itself
    /// The object of `type` with `id` its code's `init()` names, not reached yet:
    /// `{"unmade": type, "id": id}`. Building an object's instance reaches nothing, since what it
    /// holds is its journal's; its object reaches it only when it's made, or takes new code that
    /// holds one where it held nothing.
    case unmade(type: ObjectTypeName, id: ObjectIdentity)

    /// `json` as a reference, `nil` when it isn't one.
    public init?(_ json: JSONValue) {
        guard case .object(let members) = json else { return nil }
        switch (members.count, members["object"], members["type"]) {
        case (1, .string(let name)?, nil):
            self = .named(name, type: nil)
        case (2, .string(let name)?, .string(let type)?):
            self = .named(name, type: type)
        default:
            if members.count == 1, members["self"] == .bool(true) {
                self = .itself
            } else if members.count == 2, case .string(let type)? = members["unmade"],
                case .string(let id)? = members["id"]
            {
                self = .unmade(type: ObjectTypeName(rawValue: type), id: ObjectIdentity(rawValue: id))
            } else if members.count == 1, members["id"] != nil, let reference = try? json.decode(ActorReference.self) {
                self = .actor(reference, type: nil)
            } else if members.count == 2, let id = members["id"], case .string(let type)? = members["type"],
                let reference = try? JSONValue.object(["id": id]).decode(ActorReference.self)
            {
                self = .actor(reference, type: type)
            } else {
                return nil
            }
        }
    }

    /// The references anywhere in `value`.
    public static func all(in value: JSONValue) -> [ObjectReference] {
        if let reference = ObjectReference(value) { return [reference] }
        switch value {
        case .object(let members): return members.values.flatMap(all)
        case .array(let items): return items.flatMap(all)
        default: return []
        }
    }

    /// The type of the object it refers to, as the reference says it: `nil` when it doesn't.
    public var type: String? {
        switch self {
        case .actor(_, let type): type
        case .named(_, let type): type
        case .unmade(let type, _): type.rawValue
        case .itself: nil
        }
    }

    /// As it's written: what it was read from.
    public var json: JSONValue {
        get throws {
            switch self {
            case .actor(let reference, let type):
                let written = try JSONValue(encoding: reference)
                guard let type, case .object(var members) = written else { return written }
                members["type"] = .string(type)
                return .object(members)
            case .named(let name, let type?): return ["object": .string(name), "type": .string(type)]
            case .named(let name, nil): return ["object": .string(name)]
            case .itself: return ["self": true]
            case .unmade(let type, let id): return ["unmade": .string(type.rawValue), "id": .string(id.rawValue)]
            }
        }
    }
}
