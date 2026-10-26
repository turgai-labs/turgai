/// What a person may do in a group.
public enum GroupRole: String, Hashable, Codable, Sendable {
    /// Takes part, and uses what the group has.
    case member
    /// Also decides for the group: on what's asked of it.
    case admin
}

/// What happened to a group's members.
public enum GroupEvent: Hashable, Codable, Sendable {
    /// Someone is in it, with their role.
    case joined(UserID, as: GroupRole)
    /// Someone's role changed.
    case roleChanged(UserID, to: GroupRole)
}

/// The people in a group, each with their role. Who's in it is the platform's to say, as whoever
/// can write there; who decides for it is too, where the platform knows. A conversation's members
/// are one, for now; it becomes its own once something else needs it.
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

    /// `person` taking part, as someone writing in the group does: a member. None for someone
    /// already in it.
    public func admitting(_ person: UserID) -> GroupEvent? {
        members[person] == nil ? .joined(person, as: .member) : nil
    }

    /// The group's admins becoming exactly `admins`: whoever isn't in it yet joins as one, and each
    /// whose role differs has it changed. Nothing when they already are.
    public func having(admins: Set<UserID>) -> [GroupEvent] {
        let joining = admins.subtracting(members.keys).sorted { $0.rawValue < $1.rawValue }
            .map { GroupEvent.joined($0, as: .admin) }
        let changing = members.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { person -> GroupEvent? in
            let role: GroupRole = admins.contains(person) ? .admin : .member
            return members[person] == role ? nil : .roleChanged(person, to: role)
        }
        return joining + changing
    }

    /// The group after `event`: the one place its members change.
    public func applying(_ event: GroupEvent) -> Group {
        var next = self
        switch event {
        case .joined(let person, let role), .roleChanged(let person, let role):
            next.members[person] = role
        }
        return next
    }
}

/// Which group something happens in. A conversation's members are the only group for now, so a
/// group is known by its conversation's id.
public struct GroupID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The group of the conversation with `id`: its members.
    public init(_ id: ConversationID) {
        self.init(rawValue: id.stableKey)
    }
}

/// Who a call is on behalf of: whoever started its chain, as they came in.
public enum CallScope: Hashable, Codable, Sendable {
    /// A person, in the group they came in through, with the role they have there as the chain starts.
    case person(UserID, in: GroupID, as: GroupRole)
    /// Turgai itself, with no person behind it: what it starts as it launches or recovers. Only
    /// Turgai's own code starts a chain this way, never a chat.
    case runtime
}
