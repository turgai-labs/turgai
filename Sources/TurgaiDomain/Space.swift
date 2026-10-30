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
