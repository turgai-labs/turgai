import DiscoverableActors

/// Another object, as code, tools and the journal hold it: parsed once, where JSON comes in, and
/// written back as it came. A living actor is held by its ID, as an Erlang pid is; an object can
/// also be held by the name it's reached by, found at each use, as an Erlang registered name is.
public enum ObjectReference: Sendable, Equatable {
    /// A living actor, by its ID: what other kinds of objects send and take, `{"id": …}`.
    case actor(ActorReference)
    /// The object reached by this name, found at each use: `{"object": name}`.
    case named(String)
    /// A virtual actor, as Orleans has them: the object with this id and type, which is there to be
    /// used, activated on its first use when it isn't yet. Code reaches one with `Ann()`, whose id
    /// is its type's name: `{"object": id, "type": type}`.
    case virtual(id: String, type: String)
    /// The object's own code passing itself on, which its object makes its own reference:
    /// `{"self": true}`.
    case itself

    /// `json` as a reference, `nil` when it isn't one.
    public init?(_ json: JSONValue) {
        guard case .object(let members) = json else { return nil }
        switch (members.count, members["object"], members["type"]) {
        case (1, .string(let name)?, nil):
            self = .named(name)
        case (2, .string(let id)?, .string(let type)?):
            self = .virtual(id: id, type: type)
        default:
            if members.count == 1, members["self"] == .bool(true) {
                self = .itself
            } else if members.count == 1, members["id"] != nil, let reference = try? json.decode(ActorReference.self) {
                self = .actor(reference)
            } else {
                return nil
            }
        }
    }

    /// As it's written: what it was read from.
    public var json: JSONValue {
        get throws {
            switch self {
            case .actor(let reference): try JSONValue(encoding: reference)
            case .named(let name): ["object": .string(name)]
            case .virtual(let id, let type): ["object": .string(id), "type": .string(type)]
            case .itself: ["self": true]
            }
        }
    }
}
