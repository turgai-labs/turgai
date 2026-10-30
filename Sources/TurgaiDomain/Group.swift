#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What a person may do in a group.
public enum GroupRole: String, Hashable, Codable, Sendable {
    /// Takes part, and uses what the group has.
    case member
    /// Also decides for the group: on what's asked of it.
    case admin
}

/// Someone in a group, with their role there, as the group's platform says.
public struct Membership: Hashable, Codable, Sendable {
    public let person: UserID
    public let role: GroupRole

    public init(_ person: UserID, as role: GroupRole) {
        self.person = person
        self.role = role
    }
}

/// A group's own identity: minted when the group is made, and only ever given by whoever holds it,
/// never worked out from anything else.
public struct GroupID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Who a call is on behalf of, and what they may do: the person who started its chain, in the
/// group they came in through, with the role they have there and the exact requests it shares
/// with them, as the group settles them when the chain starts. Everything in the chain has them.
public struct CallScope: Hashable, Codable, Sendable {
    public let person: UserID
    public let group: GroupID
    public let role: GroupRole
    /// The exact requests they may run in it besides what an admin may: those shared with them,
    /// and those allowed once for this scope.
    public let allowed: Set<ExactRequest>

    public init(_ person: UserID, in group: GroupID, as role: GroupRole, allowed: Set<ExactRequest>) {
        self.person = person
        self.group = group
        self.role = role
        self.allowed = allowed
    }

    /// Whether exactly `request` runs in this scope: an admin decides for their group, so theirs
    /// does, and anyone's that's allowed them.
    public func allows(_ request: ExactRequest) -> Bool {
        role == .admin || allowed.contains(request)
    }
}
