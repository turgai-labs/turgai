import TurgaiDomain

/// How far someone may go with a thing, an object or an exact request: writing includes reading.
public enum AccessLevel: Int, Codable, Sendable, Comparable {
    /// Using it: calling an object's actions, or running an exact request.
    case read
    /// Changing it, and who may do what with it: deciding for it.
    case write

    public static func < (lhs: AccessLevel, rhs: AccessLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Whom a line of a thing's access is for.
public enum Audience: Hashable, Codable, Sendable {
    /// Anyone at all.
    case everyone
    /// Whoever a call says is in a group of the space.
    case group(SpaceID, GroupID)
    /// Whoever a call says may answer what's asked of the space: who decides for it.
    case deciders(of: SpaceID)
    /// One person, in whichever space they come in through.
    case person(UserID)
    /// An actor, when it's the one calling directly.
    case actor(CallActor)

    /// Whether a call on behalf of `scope` is for this audience.
    func includes(_ scope: CallScope) -> Bool {
        switch self {
        case .everyone: true
        case .group(let space, let group): space == scope.space && scope.groups.contains(group)
        case .deciders(let space): space == scope.space && scope.permissions.requests != nil
        case .person(let person): person == scope.person
        case .actor: false
        }
    }
}

/// Who may read a thing, an object or an exact request, and who may write it: one level for each
/// audience it's shared with.
public struct Access: Hashable, Codable, Sendable {
    public private(set) var levels: [Audience: AccessLevel]

    /// What a space decides for: whoever may answer what's asked of it, which no one else uses
    /// until they share it.
    public init(decidedBy space: SpaceID) {
        levels = [.deciders(of: space): .write]
    }

    /// A new object's access: its maker's alone.
    public init(madeBy maker: CallScope) {
        levels = [.person(maker.person): .write]
    }

    /// Something another actor's code made: only that actor, which holds it, may use or change it.
    /// People reach it through its holder.
    public init(heldBy holder: CallActor) {
        levels = [.actor(holder): .write]
    }

    /// Read by everyone and written by no one: what a built-in object and an agent allow, until
    /// whoever runs the node, and whoever made the agent, are known.
    public static let readByEveryone = Access(levels: [.everyone: .read])

    /// Read and written by no one: what an object allows a call from another space.
    public static let nobody = Access(levels: [:])

    private init(levels: [Audience: AccessLevel]) {
        self.levels = levels
    }

    /// How far a call on behalf of `scope` may go, if at all.
    public func level(for scope: CallScope) -> AccessLevel? {
        levels.filter { (line: (key: Audience, value: AccessLevel)) -> Bool in line.key.includes(scope) }.values.max()
    }

    /// How far the actor `caller` may go when it calls directly, if at all.
    public func level(for caller: CallActor) -> AccessLevel? {
        [levels[.actor(caller)], levels[.everyone]].compactMap { $0 }.max()
    }

    /// Whether a call coming through `chain` may go as far as `level`: whoever started it may, or
    /// the actor calling directly may.
    public func allows(_ chain: CallChain, _ level: AccessLevel) -> Bool {
        if allows(chain.scope, level) { return true }
        guard let caller = chain.actors.last, let callerLevel = self.level(for: caller) else { return false }
        return callerLevel >= level
    }

    /// Whether a call on behalf of `scope` may go as far as `level`.
    public func allows(_ scope: CallScope, _ level: AccessLevel) -> Bool {
        self.level(for: scope).map { $0 >= level } ?? false
    }

    /// The access after `audience` is given `level`, or nothing at all.
    public func sharing(with audience: Audience, _ level: AccessLevel?) -> Access {
        var next = self
        next.levels[audience] = level
        return next
    }
}

/// A call that may not go as far as it asked with a thing: reading it, or writing it.
public struct NotAllowed: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    public let level: AccessLevel

    public init(_ level: AccessLevel) {
        self.level = level
    }

    public var description: String {
        switch level {
        case .read: "Not allowed to read this object."
        case .write: "Not allowed to write this object."
        }
    }
}
