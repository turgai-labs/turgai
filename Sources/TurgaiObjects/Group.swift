import TurgaiDomain

/// What happened in a group: to its members, and to what's asked of its admins.
public enum GroupEvent: Hashable, Codable, Sendable {
    /// Someone is in it, with their role.
    case joined(UserID, as: GroupRole)
    /// Someone's role changed.
    case roleChanged(UserID, to: GroupRole)
    /// Someone asked its admins to run exactly what they may not run yet.
    case asked(AccessRequest)
    /// An admin answered.
    case answered(AccessRequestID, AccessAnswer, by: UserID)
    /// What was allowed once ran.
    case spent(AccessRequestID)
}

/// A group: the people in it, each with their role; who may run each exact request it decides,
/// as an object's access says who may use it; and what's asked of its admins until they answer.
/// Who's in it is the platform's to say, as whoever can write there; who decides for it is too,
/// where the platform knows.
public struct GroupState: Hashable, Codable, Sendable {
    public let id: GroupID
    public private(set) var members: [UserID: GroupRole]
    /// What each exact request it decided allows; the rest are its admins' alone.
    public private(set) var access: [ExactRequest: Access]
    /// What's asked of its admins: waiting for an answer, or allowed once and not yet run.
    public private(set) var requests: [AccessRequestID: AccessRequest]

    public init(id: GroupID) {
        self.id = id
        self.members = [:]
        self.access = [:]
        self.requests = [:]
    }

    /// The role `person` has here, if they're in it.
    public func role(of person: UserID) -> GroupRole? {
        members[person]
    }

    /// The people who decide for the group.
    public var admins: Set<UserID> {
        Set(members.filter { $0.value == .admin }.keys)
    }

    /// Whom a call `person` makes here is on behalf of: them, in this group, with the role they
    /// have in it now and the exact requests shared with them.
    public func scope(of person: UserID) -> CallScope {
        let role = role(of: person) ?? .member
        let asThem = CallScope(person, in: id, as: role, allowed: [])
        let shared = access.filter { $0.value.allows(asThem, .read) }.keys
        return CallScope(person, in: id, as: role, allowed: Set(shared))
    }

    /// The scope of a chain `person` starts here, as it opens: theirs, with what an admin allowed
    /// them once besides, which opening it spends.
    public func opening(scopeOf person: UserID) -> (CallScope, [GroupEvent]) {
        let scope = scope(of: person)
        let once = requests.values.filter { $0.by == person && $0.standing == .allowedOnce }
            .sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        return (
            CallScope(person, in: id, as: scope.role, allowed: scope.allowed.union(once.map(\.request))),
            once.map { .spent($0.id) }
        )
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

    /// `person` having `role`, as the group's platform says: joining with it, or changing to it.
    /// None when they already have it.
    public func setting(_ role: GroupRole, of person: UserID) -> GroupEvent? {
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

    /// The request `person` asked for exactly `request` with, while it's open.
    public func request(for request: ExactRequest, by person: UserID) -> AccessRequest? {
        requests.values.first { $0.request == request && $0.by == person }
    }

    /// `person` asking its admins to run exactly `request`, which their scope didn't allow: a new
    /// request, `id`, unless theirs is already open or it's since been shared with them.
    public func requesting(_ request: ExactRequest, by person: UserID, id: AccessRequestID) -> [GroupEvent] {
        guard self.request(for: request, by: person) == nil, !scope(of: person).allows(request) else { return [] }
        return [.asked(AccessRequest(id: id, request: request, by: person, standing: .waiting))]
    }

    /// `answer` to the request `id`, by a call on behalf of `scope`: nothing unless it waits and
    /// they may decide for what it asks, as writing it.
    public func answering(_ id: AccessRequestID, _ answer: AccessAnswer, by scope: CallScope) -> [GroupEvent] {
        guard let open = requests[id], open.standing == .waiting,
            access(to: open.request).allows(scope, .write)
        else { return [] }
        return [.answered(id, answer, by: scope.person)]
    }

    /// The group after `event`: the one place it changes.
    public func applying(_ event: GroupEvent) -> GroupState {
        var next = self
        switch event {
        case .joined(let person, let role), .roleChanged(let person, let role):
            next.members[person] = role
        case .asked(let request):
            next.requests[request.id] = request
        case .answered(let id, let answer, _):
            guard let open = requests[id] else { return next }
            switch answer {
            case .once:
                next.requests[id] = open.standing(.allowedOnce)
            case .always:
                next.requests[id] = nil
                next.access[open.request] = access(to: open.request).sharing(with: .person(open.by), .read)
            case .everyone:
                next.requests[id] = nil
                next.access[open.request] = access(to: open.request).sharing(with: .group(self.id), .read)
            case .no:
                next.requests[id] = nil
            }
        case .spent(let id):
            next.requests[id] = nil
        }
        return next
    }
}
