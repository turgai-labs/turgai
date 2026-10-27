import DiscoverableActors
import Distributed
import DistributedCluster
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

    /// Whether a call on behalf of `scope` is for this audience.
    func includes(_ scope: CallScope) -> Bool {
        switch self {
        case .everyone: true
        case .group(let group): group == scope.group
        case .admins(let group): group == scope.group && scope.role == .admin
        case .person(let person): person == scope.person
        case .object: false
        }
    }
}

/// Who may read an object and who may write it: one level for each audience it's shared with.
public struct ObjectAccess: Hashable, Codable, Sendable {
    public private(set) var levels: [Audience: AccessLevel]

    /// A new object's access: its maker's alone.
    public init(madeBy maker: CallScope) {
        levels = [.person(maker.person): .write]
    }

    /// Read by everyone and written by no one: what a built-in object and an agent allow, until
    /// whoever runs the node, and whoever made the agent, are known.
    public static let readByEveryone = ObjectAccess(levels: [.everyone: .read])

    private init(levels: [Audience: AccessLevel]) {
        self.levels = levels
    }

    /// How far a call on behalf of `scope` may go, if at all.
    public func level(for scope: CallScope) -> AccessLevel? {
        levels.filter { (line: (key: Audience, value: AccessLevel)) -> Bool in line.key.includes(scope) }.values.max()
    }

    /// How far the object `caller` may go when it calls directly, if at all.
    public func level(for caller: ObjectID) -> AccessLevel? {
        [levels[.object(caller)], levels[.everyone]].compactMap { $0 }.max()
    }

    /// Whether a call coming through `chain` may go as far as `level`: whoever started it may, or
    /// the object calling directly may.
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
    func sharing(with audience: Audience, _ level: AccessLevel?) -> ObjectAccess {
        var next = self
        next.levels[audience] = level
        return next
    }
}

/// A call that may not go as far as it asked with an object: reading it, or writing it.
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

/// An object that says who may read it and who may write it. An object that doesn't is refused
/// every call: each kind of object says its own.
public protocol AccessControlled: DistributedActor where ActorSystem == ClusterSystem {
    /// Who may read it and who may write it, for a call through `chain`.
    func access(for chain: CallChain) -> ObjectAccess
}

extension AccessControlled {
    /// Refuses a call, before it runs, whose chain may not read it.
    nonisolated func checkReading() async throws {
        let chain = CallChain.current
        let object = id.virtualActorID.map(ObjectID.virtual) ?? .actor(id, type: nil)
        try await whenLocal { local in
            guard let chain else { throw CallOnBehalfOfNoOne(actor: object) }
            guard local.access(for: chain).allows(chain, .read) else { throw NotAllowed(.read) }
        }
    }
}

extension ClusterSystemSettings {
    /// Checks every call to an object before it runs, on whichever node it lives: a call from
    /// another node, or one through a reference here. A call is on someone's behalf, who may read
    /// the object; one that changes it, the object refuses as it decides the change, unless they
    /// may write it. An object that doesn't say who may read it is refused.
    public mutating func checkObjectAccess() {
        remoteCall.incomingCallFilter = { actor, _ in
            if let object = actor as? any AccessControlled {
                try await object.checkReading()
            } else if actor is any DiscoverableActor {
                throw NotAllowed(.read)
            }
        }
    }
}
