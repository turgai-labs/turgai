#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What a person may do in a space.
public enum SpaceRole: String, Hashable, Codable, Sendable {
    /// Takes part, and uses what the space has.
    case member
    /// Also decides for the space: on what's asked of it.
    case admin
}

/// Someone in a space, with their role there, as the space's platform says.
public struct Membership: Hashable, Codable, Sendable {
    public let person: UserID
    public let role: SpaceRole

    public init(_ person: UserID, as role: SpaceRole) {
        self.person = person
        self.role = role
    }
}

/// A space's own identity: minted when the space is made, and only ever given by whoever holds it,
/// never worked out from anything else.
public struct SpaceID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// What a space is called, as the people who made it named it: some words, at most 80 letters.
public struct SpaceName: Hashable, Codable, Sendable, CustomStringConvertible {
    public static let maximumLength = 80

    public let rawValue: String

    /// The name `written`, without the space around it: none when there's nothing, or too much.
    public init?(_ written: String) {
        let name = written.trimmed()
        guard !name.isEmpty, name.count <= Self.maximumLength else { return nil }
        self.rawValue = name
    }

    public var description: String { rawValue }
}

public struct SpaceInviteID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// An invite's token as a space keeps it: only its hash, so nothing kept lets anyone in.
public struct SpaceInviteHash: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// How long an invite works, as whoever made it chose: until it's used, or until a time.
public enum SpaceInviteLifetime: Hashable, Codable, Sendable {
    case untilUsed
    case until(Date)
}

/// An open invite to a space: one person's way in, once.
public struct SpaceInvite: Hashable, Codable, Sendable {
    public let id: SpaceInviteID
    public let hash: SpaceInviteHash
    /// The admin who made it.
    public let by: UserID
    public let lifetime: SpaceInviteLifetime

    public init(id: SpaceInviteID = SpaceInviteID(), hash: SpaceInviteHash, by: UserID, lifetime: SpaceInviteLifetime) {
        self.id = id
        self.hash = hash
        self.by = by
        self.lifetime = lifetime
    }

    /// Whether it still works at `now`.
    public func works(at now: Date) -> Bool {
        switch lifetime {
        case .untilUsed: true
        case .until(let end): now < end
        }
    }
}

/// Who a call is on behalf of, and what they may do: the person who started its chain, in the
/// space they came in through, with the role they have there and the exact requests it shares
/// with them, as the space settles them when the chain starts. Everything in the chain has them.
public struct CallScope: Hashable, Codable, Sendable {
    public let person: UserID
    public let space: SpaceID
    public let role: SpaceRole
    /// The exact requests they may run in it besides what an admin may: those shared with them,
    /// and those allowed once for this scope.
    public let allowed: Set<ExactRequest>

    public init(_ person: UserID, in space: SpaceID, as role: SpaceRole, allowed: Set<ExactRequest>) {
        self.person = person
        self.space = space
        self.role = role
        self.allowed = allowed
    }

    /// Whether exactly `request` runs in this scope: an admin decides for their space, so theirs
    /// does, and anyone's that's allowed them.
    public func allows(_ request: ExactRequest) -> Bool {
        role == .admin || allowed.contains(request)
    }
}
