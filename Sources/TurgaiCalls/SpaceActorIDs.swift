public import AttributedCalls
public import Foundation
public import TurgaiDomain
public import VirtualActors

extension VirtualActorID {
    /// The id of the space `id` itself: no other actor owns it, so anyone calls it, and it decides.
    public static func space(_ id: SpaceID) -> VirtualActorID {
        VirtualActorID("space", id.rawValue.uuidString)
    }

    /// The id of the `kind` called `name` that the space `space` owns: only the space, and what
    /// else it owns, call it.
    public static func owned(by space: SpaceID, _ kind: String, _ name: String) -> VirtualActorID {
        VirtualActorID(kind, name, in: .space(space))
    }

    /// The id of the person `id`'s own actor: no other actor owns it. What a person asks of a
    /// space comes from it, so the space is told who asked by the call itself.
    public static func user(_ id: UserID) -> VirtualActorID {
        VirtualActorID("user", id.key)
    }

    /// The id of `actor`, one of a space's own.
    public init(_ actor: SpaceActor) {
        self.init([Step("space", actor.space.rawValue.uuidString)] + actor.steps.map { Step($0.kind, $0.name) })
    }

    /// The person whose own actor this is the id of: none for another actor's.
    public var user: UserID? {
        guard let steps, steps.count == 1, steps[0].kind == "user" else { return nil }
        return try? UserID(key: steps[0].name)
    }

    /// The space this is the id of: none for another actor's.
    public var space: SpaceID? {
        guard let steps, steps.count == 1, steps[0].kind == "space", let id = UUID(uuidString: steps[0].name)
        else { return nil }
        return SpaceID(rawValue: id)
    }

    /// The actor of a space this is the id of: none for an id that isn't one space's own.
    public var spaceActor: SpaceActor? {
        guard let steps, steps.count > 1, steps[0].kind == "space", let id = UUID(uuidString: steps[0].name)
        else { return nil }
        let own = steps.dropFirst().map { SpaceActor.Step($0.kind, $0.name) }
        return SpaceActor(in: SpaceID(rawValue: id), own[0], Array(own.dropFirst()))
    }

    /// What a space's own actor's id says: its space, its kind and its name there. None for an id
    /// that isn't one space's own, or that goes deeper than a kind and a name.
    public var owned: (space: SpaceID, kind: String, name: String)? {
        guard let actor = spaceActor, actor.rest.isEmpty else { return nil }
        return (actor.space, actor.first.kind, actor.first.name)
    }
}

/// An id that says neither a person's own actor nor one of a space's own: no one a space is asked
/// by.
public struct NotAParty: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public let id: VirtualActorID

    public var description: String { "\(id.rawValue) is neither a person nor one of a space's actors" }
}

extension Party {
    /// The party the actor `id` is: a person, for a person's own actor; one of a space's own, for
    /// one of those. Refused for any other id.
    public init(_ id: VirtualActorID) throws(NotAParty) {
        if let person = id.user {
            self = .person(person)
        } else if let actor = id.spaceActor {
            self = .actor(actor)
        } else {
            throw NotAParty(id: id)
        }
    }

    /// The id of the actor it asks as: a person's own, or its own.
    public var actorID: VirtualActorID {
        switch self {
        case .person(let person): .user(person)
        case .actor(let actor): VirtualActorID(actor)
        }
    }
}
