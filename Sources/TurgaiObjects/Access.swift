import TurgaiDomain

/// How far someone may go with an object: writing includes reading.
public enum AccessLevel: Int, Codable, Sendable, Comparable {
    /// Using it: calling its actions.
    case read
    /// Changing it: its code, its name, removing it, and who may do what.
    case write

    public static func < (lhs: AccessLevel, rhs: AccessLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Whom a line of an object's access is for.
public enum Audience: Hashable, Codable, Sendable {
    /// Anyone at all.
    case everyone
    /// Anyone a call says is in the group.
    case group(GroupID)
    /// Only those a call says are the group's admins.
    case admins(of: GroupID)
    /// One person, in whichever group they come in through.
    case person(UserID)
    /// An object, when it's the one calling directly.
    case object(ObjectID)
    /// Turgai itself, with no person behind it.
    case turgai

    /// Whether a call on behalf of `scope` is for this audience.
    func includes(_ scope: CallScope) -> Bool {
        switch (self, scope) {
        case (.everyone, _): true
        case (.group(let group), .person(_, let scopeGroup, _)): group == scopeGroup
        case (.admins(let group), .person(_, let scopeGroup, let role)): group == scopeGroup && role == .admin
        case (.person(let person), .person(let scopePerson, _, _)): person == scopePerson
        case (.turgai, .runtime): true
        case (.group, .runtime), (.admins, .runtime), (.person, .runtime), (.object, _), (.turgai, .person): false
        }
    }
}

/// Who may read an object and who may write it: one level for each audience it's shared with.
public struct ObjectAccess: Hashable, Codable, Sendable {
    public private(set) var levels: [Audience: AccessLevel]

    /// A new object's access: its maker's alone. One Turgai makes itself is everyone's to read.
    public init(madeBy maker: CallScope) {
        switch maker {
        case .person(let person, _, _): levels = [.person(person): .write]
        case .runtime: levels = [.turgai: .write, .everyone: .read]
        }
    }

    /// How far a call on behalf of `scope` may go, if at all.
    public func level(for scope: CallScope) -> AccessLevel? {
        levels.filter { (line: (key: Audience, value: AccessLevel)) -> Bool in line.key.includes(scope) }.values.max()
    }

    /// How far the object `caller` may go when it calls directly, if at all.
    public func level(for caller: ObjectID) -> AccessLevel? {
        [levels[.object(caller)], levels[.everyone]].compactMap { $0 }.max()
    }

    /// Whether a call on behalf of `scope` may go as far as `level`.
    public func allows(_ scope: CallScope, _ level: AccessLevel) -> Bool {
        self.level(for: scope).map { $0 >= level } ?? false
    }

    /// The access after `audience` is given `level`, or nothing at all.
    func sharing(with audience: Audience, _ level: AccessLevel?) -> ObjectAccess {
        var next = self
        next.levels[audience] = level
        return next
    }
}
