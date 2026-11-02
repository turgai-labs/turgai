import DistributedCluster
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What a person does with spaces, as Turgai's apps ask it: making one, their list, renaming,
/// inviting someone, joining with an invite, and leaving.
public struct Spaces: Sendable {
    private let actorSystem: ClusterSystem

    public init(actorSystem: ClusterSystem) {
        self.actorSystem = actorSystem
    }

    /// A new space called `name`, with `person` its first admin.
    public func make(named name: SpaceName, by person: UserID) async throws -> SpaceListing {
        let id = SpaceID()
        let space = try await Space.resolve(on: actorSystem, id: id)
        try await space.make(named: name, by: person)
        return try await listing(of: space, for: person)
    }

    /// The named spaces `person` is in, the first joined first, as the space directory has them.
    public func list(for person: UserID) async throws -> [SpaceListing] {
        try await actorSystem.singleton.proxy(SpaceDirectory.self, name: SpaceDirectory.singletonName)
            .spaces(of: person)
    }

    /// The space `id` called `name` from now on, as its admin `person` asks.
    public func rename(_ id: SpaceID, to name: SpaceName, by person: UserID) async throws -> SpaceListing {
        let space = try await Space.resolve(on: actorSystem, id: id)
        try await space.rename(to: name, by: person)
        return try await listing(of: space, for: person)
    }

    /// `person` leaving the space `id`.
    public func leave(_ id: SpaceID, as person: UserID) async throws {
        try await Space.resolve(on: actorSystem, id: id).leave(person)
    }

    /// A new invite to the space `id`, made by its admin `person`, working for `lifetime`: the
    /// invite, and the token its link carries, which only this answer ever holds.
    public func invite(to id: SpaceID, by person: UserID, for lifetime: SpaceInviteLifetime) async throws
        -> (invite: SpaceInvite, token: SpaceInviteToken)
    {
        let token = SpaceInviteToken.new()
        let invite = SpaceInvite(hash: token.hash, by: person, lifetime: lifetime)
        try await Space.resolve(on: actorSystem, id: id).invite(invite)
        return (invite, token)
    }

    /// Who's in the space `id`, each with their role, as `person`, one of them, sees them.
    public func people(in id: SpaceID, for person: UserID) async throws -> [UserID: SpaceRole] {
        try await Space.resolve(on: actorSystem, id: id).people(for: person)
    }

    /// The invites to the space `id` that still work, as its admin `person` sees them.
    public func invites(to id: SpaceID, for person: UserID) async throws -> [SpaceInvite] {
        try await Space.resolve(on: actorSystem, id: id).openInvites(for: person)
    }

    /// The invite `invite` to the space `id` taken back, as its admin `person` asks.
    public func takeBack(_ invite: SpaceInviteID, to id: SpaceID, by person: UserID) async throws {
        try await Space.resolve(on: actorSystem, id: id).takeBack(invite, by: person)
    }

    /// `person` joining the space `id` with `token`, an invite's.
    public func join(_ id: SpaceID, with token: SpaceInviteToken, as person: UserID) async throws -> SpaceListing {
        let space = try await Space.resolve(on: actorSystem, id: id)
        try await space.join(with: token.hash, as: person)
        return try await listing(of: space, for: person)
    }

    private func listing(of space: Space, for person: UserID) async throws -> SpaceListing {
        guard let listing = try await space.listing(for: person) else { throw SpaceRefusal.notInIt }
        return listing
    }
}
