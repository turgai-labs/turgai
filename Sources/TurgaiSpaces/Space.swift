import TurgaiCalls
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

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
    /// It's called `name`, as whoever made it, or an admin since, named it.
    case named(SpaceName)
    /// Someone left it.
    case left(UserID)
    /// An admin made an invite.
    case invited(SpaceInvite)
    /// Someone joined with the invite, which is spent.
    case inviteUsed(SpaceInviteID, by: UserID)
    /// An admin took the invite back.
    case inviteTakenBack(SpaceInviteID)
}

/// A space a person is in, as their list shows it: what it's called, and the role they have.
public struct SpaceListing: Hashable, Codable, Sendable {
    public let id: SpaceID
    public let name: SpaceName
    public let role: SpaceRole

    public init(id: SpaceID, name: SpaceName, role: SpaceRole) {
        self.id = id
        self.name = name
        self.role = role
    }
}

/// Why a space didn't do what it was asked.
public enum SpaceRefusal: Error, Equatable, Codable, Sendable, CustomStringConvertible {
    /// It's made already: it has a name, or people.
    case alreadyMade
    /// A guest neither makes a space nor joins one.
    case guestsStayOut
    /// Only its admins may.
    case onlyAdmins
    /// They're not in it.
    case notInIt
    /// They're its last admin: someone else has to be one first.
    case lastAdmin
    /// No invite like it works: it was used, taken back, or ran out, or there never was one.
    case inviteDoesNotWork
    /// It was made with a conversation, and is that conversation's: no one is invited into it.
    case aConversations

    public var description: String {
        switch self {
        case .alreadyMade: "This space is made already."
        case .guestsStayOut: "A guest can't make or join a space: sign in first."
        case .onlyAdmins: "Only its admins can do that."
        case .notInIt: "You're not in this space."
        case .lastAdmin: "You're its last admin: make someone else an admin first."
        case .inviteDoesNotWork: "This invite doesn't work: it's been used, taken back, or has run out."
        case .aConversations: "This space is a conversation's own: no one is invited into it."
        }
    }
}

/// A space: the people in it, each with their role; who may run each exact request it decides,
/// as an object's access says who may use it; and what's asked of its admins until they answer.
/// Who's in it is the platform's to say, as whoever can write there; who decides for it is too,
/// where the platform knows.
public struct SpaceState: Hashable, Codable, Sendable {
    public let id: SpaceID
    /// What it's called: none for one made with a conversation, which is that conversation's.
    public private(set) var name: SpaceName?
    public private(set) var members: [UserID: SpaceRole]
    /// The invites its admins made that aren't spent, by id.
    public private(set) var invites: [SpaceInviteID: SpaceInvite]
    /// What each exact request it decided allows; the rest are its admins' alone.
    public private(set) var access: [ExactRequest: Access]
    /// What's asked of its admins: waiting for an answer, or allowed once and not yet run.
    public private(set) var requests: [AccessRequestID: AccessRequest]
    /// Who asked each: the one what it allows once goes to.
    public private(set) var askers: [AccessRequestID: Asker]

    public init(id: SpaceID) {
        self.id = id
        self.name = nil
        self.members = [:]
        self.invites = [:]
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
        let joining = admins.subtracting(members.keys).sorted { $0.key < $1.key }
            .map { SpaceEvent.joined($0, as: .admin) }
        let changing = members.keys.sorted { $0.key < $1.key }.compactMap { person -> SpaceEvent? in
            let role: SpaceRole = admins.contains(person) ? .admin : .member
            return members[person] == role ? nil : .roleChanged(person, to: role)
        }
        return joining + changing
    }

    /// The accounts in it becoming exactly `accounts`, each with its role, as Turgai's accounts
    /// say: whoever isn't in it joins, each whose role differs has it changed, and an account
    /// that's not among them leaves. Anyone who isn't an account stays as they are.
    public func having(accounts: [UserID: SpaceRole]) -> [SpaceEvent] {
        let joiningOrChanging = accounts.sorted { $0.key.key < $1.key.key }.compactMap { person, role in
            setting(role, of: person)
        }
        let leaving = members.keys.filter { person in
            if case .account = person { accounts[person] == nil } else { false }
        }
        .sorted { $0.key < $1.key }.map(SpaceEvent.left)
        return joiningOrChanging + leaving
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

    /// It made, called `name`, with `person` its first admin.
    public func making(named name: SpaceName, by person: UserID) throws(SpaceRefusal) -> [SpaceEvent] {
        guard !person.isGuest else { throw .guestsStayOut }
        guard self.name == nil, members.isEmpty else { throw .alreadyMade }
        return [.named(name), .joined(person, as: .admin)]
    }

    /// It called `name` from now on, as its admin `person` renames it.
    public func renaming(to name: SpaceName, by person: UserID) throws(SpaceRefusal) -> [SpaceEvent] {
        guard members[person] == .admin else { throw .onlyAdmins }
        return name == self.name ? [] : [.named(name)]
    }

    /// `invite` open, as its admin made it.
    public func inviting(_ invite: SpaceInvite) throws(SpaceRefusal) -> [SpaceEvent] {
        guard name != nil else { throw .aConversations }
        guard members[invite.by] == .admin else { throw .onlyAdmins }
        return [.invited(invite)]
    }

    /// The invite `id` taken back by its admin `person`: none when it's spent already.
    public func takingBack(_ id: SpaceInviteID, by person: UserID) throws(SpaceRefusal) -> [SpaceEvent] {
        guard members[person] == .admin else { throw .onlyAdmins }
        return invites[id] == nil ? [] : [.inviteTakenBack(id)]
    }

    /// `person` joining as a member with the invite whose token hashes to `hash`, which that spends:
    /// none for someone in it already, who leaves the invite for another.
    public func joining(with hash: SpaceInviteHash, as person: UserID, at now: Date) throws(SpaceRefusal)
        -> [SpaceEvent]
    {
        guard !person.isGuest else { throw .guestsStayOut }
        guard let invite = invites.values.first(where: { $0.hash == hash }), invite.works(at: now) else {
            throw .inviteDoesNotWork
        }
        guard members[person] == nil else { return [] }
        return [.inviteUsed(invite.id, by: person), .joined(person, as: .member)]
    }

    /// `person` leaving: refused when they're not in it, or they're its last admin.
    public func leaving(_ person: UserID) throws(SpaceRefusal) -> [SpaceEvent] {
        guard let role = members[person] else { throw .notInIt }
        guard role != .admin || admins.count > 1 else { throw .lastAdmin }
        return [.left(person)]
    }

    /// The invites that still work at `now`, as its admins see them, the earliest made first.
    public func openInvites(at now: Date) -> [SpaceInvite] {
        invites.values.filter { $0.works(at: now) }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
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

    /// The space after `events`, in order.
    public func applying(_ events: [SpaceEvent]) -> SpaceState {
        events.reduce(self) { $0.applying($1) }
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
        case .named(let name):
            next.name = name
        case .left(let person):
            next.members[person] = nil
        case .invited(let invite):
            next.invites[invite.id] = invite
        case .inviteUsed(let id, _), .inviteTakenBack(let id):
            next.invites[id] = nil
        }
        return next
    }
}
