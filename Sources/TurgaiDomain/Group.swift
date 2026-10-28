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

/// Which group something happens in: a conversation's, known by the conversation's id, or the
/// dashboard's.
public struct GroupID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The group of the conversation with `id`: its members.
    public init(_ id: ConversationID) {
        self.init(rawValue: id.stableKey)
    }

    /// The dashboard's group: the accounts that sign in to it, its administrators as its admins.
    public static let dashboard = GroupID(rawValue: "dashboard")
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
