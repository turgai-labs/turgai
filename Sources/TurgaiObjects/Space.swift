import TurgaiDomain

/// What happened in a space: to its members, and to what's asked of its admins.
public enum SpaceEvent: Hashable, Codable, Sendable {
    /// Someone is in it, with their role.
    case joined(UserID, as: SpaceRole)
    /// Someone's role changed.
    case roleChanged(UserID, to: SpaceRole)
    /// Someone asked its admins to run exactly what they may not run yet: themselves, or an
    /// object's own work, done for them.
    case asked(AccessRequest, by: Asker)
    /// An admin answered.
    case answered(AccessRequestID, AccessAnswer, by: UserID)
    /// What was allowed once ran.
    case spent(AccessRequestID)
}

/// Who asked for what an admin then allows once: a person, themselves, or one object's own work,
/// done for its maker. What's allowed once goes to exactly the one that asked.
public enum Asker: Hashable, Codable, Sendable {
    case person
    case object(ObjectIdentity)
}

/// A space: the people in it, each with their role; who may run each exact request it decides,
/// as an object's access says who may use it; and what's asked of its admins until they answer.
/// Who's in it is the platform's to say, as whoever can write there; who decides for it is too,
/// where the platform knows.
public struct SpaceState: Hashable, Codable, Sendable {
    public let id: SpaceID
    public private(set) var members: [UserID: SpaceRole]
    /// What each exact request it decided allows; the rest are its admins' alone.
    public private(set) var access: [ExactRequest: Access]
    /// What's asked of its admins: waiting for an answer, or allowed once and not yet run.
    public private(set) var requests: [AccessRequestID: AccessRequest]
    /// Who asked each: the one what it allows once goes to.
    public private(set) var askers: [AccessRequestID: Asker]

    public init(id: SpaceID) {
        self.id = id
        self.members = [:]
        self.access = [:]
        self.requests = [:]
        self.askers = [:]
    }

    /// The role `person` has here, if they're in it.
    public func role(of person: UserID) -> SpaceRole? {
        members[person]
    }

    /// The people who decide for the space.
    public var admins: Set<UserID> {
        Set(members.filter { $0.value == .admin }.keys)
    }

    /// Whom a call `person` makes here is on behalf of: them, in this space, with the role they
    /// have in it now and the exact requests shared with them.
    public func scope(of person: UserID) -> CallScope {
        let role = role(of: person) ?? .member
        let asThem = CallScope(person, in: id, as: role, allowed: [])
        let shared = access.filter { $0.value.allows(asThem, .read) }.keys
        return CallScope(person, in: id, as: role, allowed: Set(shared))
    }

    /// The scope of a chain `person` starts here for `asker`, as it opens: theirs, with what an
    /// admin allowed `asker` once besides, which opening it spends. What another asked for, even
    /// for them, it doesn't take.
    public func opening(scopeOf person: UserID, for asker: Asker) -> (CallScope, [SpaceEvent]) {
        let scope = scope(of: person)
        let once = requests.values.filter {
            $0.by == person && askers[$0.id] == asker && $0.standing == .allowedOnce
        }
            .sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        return (
            CallScope(person, in: id, as: scope.role, allowed: scope.allowed.union(once.map(\.request))),
            once.map { .spent($0.id) }
        )
    }

    /// `person` taking part, as someone writing in the space does: a member. None for someone
    /// already in it.
    public func admitting(_ person: UserID) -> SpaceEvent? {
        members[person] == nil ? .joined(person, as: .member) : nil
    }

    /// The space's admins becoming exactly `admins`: whoever isn't in it yet joins as one, and each
    /// whose role differs has it changed. Nothing when they already are.
    public func having(admins: Set<UserID>) -> [SpaceEvent] {
        let joining = admins.subtracting(members.keys).sorted { $0.rawValue < $1.rawValue }
            .map { SpaceEvent.joined($0, as: .admin) }
        let changing = members.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { person -> SpaceEvent? in
            let role: SpaceRole = admins.contains(person) ? .admin : .member
            return members[person] == role ? nil : .roleChanged(person, to: role)
        }
        return joining + changing
    }

    /// `person` having `role`, as the space's platform says: joining with it, or changing to it.
    /// None when they already have it.
    public func setting(_ role: SpaceRole, of person: UserID) -> SpaceEvent? {
        switch members[person] {
        case nil: .joined(person, as: role)
        case role?: nil
        case _?: .roleChanged(person, to: role)
        }
    }

    /// Who may run exactly `request` here, and who decides that.
    public func access(to request: ExactRequest) -> Access {
        access[request] ?? Access(decidedBy: id)
    }

    /// The request `asker` asked for exactly `request` with, for `person`, while it's open.
    public func request(for request: ExactRequest, by person: UserID, as asker: Asker) -> AccessRequest? {
        requests.values.first { $0.request == request && $0.by == person && askers[$0.id] == asker }
    }

    /// `asker` asking its admins, for `person`, to run exactly `request`, which their scope didn't
    /// allow: a new request, `id`, unless it's already asked for it or it's since been shared with them.
    public func requesting(_ request: ExactRequest, by person: UserID, as asker: Asker, id: AccessRequestID)
        -> [SpaceEvent]
    {
        guard self.request(for: request, by: person, as: asker) == nil, !scope(of: person).allows(request) else {
            return []
        }
        return [.asked(AccessRequest(id: id, request: request, by: person, standing: .waiting), by: asker)]
    }

    /// `answer` to the request `id`, by a call on behalf of `scope`: nothing unless it waits and
    /// they may decide for what it asks, as writing it.
    public func answering(_ id: AccessRequestID, _ answer: AccessAnswer, by scope: CallScope) -> [SpaceEvent] {
        guard let open = requests[id], open.standing == .waiting,
            access(to: open.request).allows(scope, .write)
        else { return [] }
        return [.answered(id, answer, by: scope.person)]
    }

    /// The space after `event`: the one place it changes.
    public func applying(_ event: SpaceEvent) -> SpaceState {
        var next = self
        switch event {
        case .joined(let person, let role), .roleChanged(let person, let role):
            next.members[person] = role
        case .asked(let request, let asker):
            next.requests[request.id] = request
            next.askers[request.id] = asker
        case .answered(let id, let answer, _):
            guard let open = requests[id] else { return next }
            switch answer {
            case .once:
                next.requests[id] = open.standing(.allowedOnce)
            case .always:
                next.requests[id] = nil
                next.askers[id] = nil
                next.access[open.request] = access(to: open.request).sharing(with: .person(open.by), .read)
            case .everyone:
                next.requests[id] = nil
                next.askers[id] = nil
                next.access[open.request] = access(to: open.request).sharing(with: .space(self.id), .read)
            case .no:
                next.requests[id] = nil
                next.askers[id] = nil
            }
        case .spent(let id):
            next.requests[id] = nil
            next.askers[id] = nil
        }
        return next
    }
}
