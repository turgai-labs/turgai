/// What a person may do in a group.
public enum GroupRole: String, Hashable, Codable, Sendable {
    /// Takes part, and uses what the group has.
    case member
    /// Also decides for the group: on what's asked of it, and who's in it.
    case admin
}

/// What happened to a group's members.
public enum GroupEvent: Hashable, Codable, Sendable {
    case joined(UserID, as: GroupRole)
}

/// The people in a group, each with their role. A conversation's members are one, for now; it
/// becomes its own once something else needs it.
public struct Group: Hashable, Codable, Sendable {
    public private(set) var members: [UserID: GroupRole]

    public init() {
        self.members = [:]
    }

    /// The role `person` has here, if they're in it.
    public func role(of person: UserID) -> GroupRole? {
        members[person]
    }

    /// The people who decide for the group.
    public var admins: Set<UserID> {
        Set(members.filter { $0.value == .admin }.keys)
    }

    /// `person` joining, as someone writing in the group does: the first to join is its admin.
    /// None for someone already in it.
    public func admitting(_ person: UserID) -> GroupEvent? {
        guard members[person] == nil else { return nil }
        return .joined(person, as: members.isEmpty ? .admin : .member)
    }

    /// The group after `event`: the one place its members change.
    public func applying(_ event: GroupEvent) -> Group {
        var next = self
        switch event {
        case .joined(let person, let role):
            next.members[person] = role
        }
        return next
    }
}
