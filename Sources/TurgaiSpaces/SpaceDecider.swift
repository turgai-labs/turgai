import TurgaiCalls
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What happened in a space: to its people and groups, and to what's asked of it.
public enum SpaceEvent: Hashable, Codable, Sendable {
    /// It was made, called `name`, with `admins` deciding for it, `groups`, each with what it may,
    /// its members group among them, and its first bot, its main.
    case made(SpaceName, admins: NonEmptySet<UserID>, groups: [GroupID: Permissions], main: Bot)
    /// It's called `name`, as an admin since named it.
    case named(SpaceName)
    /// Someone is in it, in `inGroups`.
    case joined(UserID, inGroups: NonEmptySet<GroupID>)
    /// Someone is in exactly `inGroups` from now on.
    case placed(UserID, inGroups: NonEmptySet<GroupID>)
    /// Someone left it.
    case left(UserID)
    /// Someone is one of its admins, who may do everything in it: in it from now on, if they
    /// weren't.
    case adminMade(UserID)
    /// Someone is no longer one of its admins: they're in `inGroups`, and may what those may.
    case adminSteppedDown(UserID, inGroups: NonEmptySet<GroupID>)
    /// A group was made, which may what `permissions` says.
    case groupMade(GroupID, Permissions)
    /// A group may what `permissions` says from now on.
    case permissionsSet(GroupID, Permissions)
    /// A group is gone: whoever was in it is in their other groups.
    case groupRemoved(GroupID)
    /// A bot was added.
    case botAdded(Bot)
    /// A bot is as `bot` says from now on: what it's called, how it behaves, or what thinks for it.
    case botChanged(Bot)
    /// A bot is gone: it's in none of its conversations any more.
    case botRemoved(BotID)
    /// The bot is the main one from now on: the one that answers when no other is asked for, or
    /// the one asked for is gone.
    case mainChosen(BotID)
    /// A connection is a way into it from a platform: it runs while it's enabled.
    case connectionAdded(Connection)
    /// A connection is as it says from now on.
    case connectionChanged(Connection)
    /// A connection is no way into it any more.
    case connectionRemoved(ConnectionID)
    /// Someone asked it to run exactly what they may not run yet: themselves, or an object's own
    /// work, done for them.
    case asked(AccessRequest, by: Asker)
    /// Someone who decides for it answered.
    case answered(AccessRequestID, AccessAnswer, by: UserID)
    /// What was allowed once ran.
    case spent(AccessRequestID)
    /// Someone who manages its people made an invite.
    case invited(SpaceInvite)
    /// Someone joined with the invite, which is spent.
    case inviteUsed(SpaceInviteID, by: UserID)
    /// The invite was taken back.
    case inviteTakenBack(SpaceInviteID)
    /// It was archived: it's kept to be read, and nothing new happens in it.
    case archived(by: UserID)
    /// It's in use again.
    case unarchived(by: UserID)
}

/// What a space is asked to do, and by whom.
public enum SpaceCommand: Hashable, Sendable {
    /// Make it, called `name`, with `person` its first admin and `bot` its first bot.
    case make(named: SpaceName, by: UserID, bot: Bot)
    /// Make it as its platform says: called `name`, with `admins` deciding for it, `groups` besides
    /// its members group, and `bot` its first bot.
    case makeForPlatform(named: SpaceName, admins: NonEmptySet<UserID>, groups: [GroupID: Permissions], bot: Bot)
    /// It as the accounts that sign in to it say it is: called `name`, `admins` its admins and
    /// `others` its members.
    /// Its admins are exactly `admins` from now on, as its platform says.
    case setAdmins(NonEmptySet<UserID>)
    /// `person` takes part, as someone writing in it does, in `groups`: the way they came in says
    /// which.
    case admit(UserID, into: NonEmptySet<GroupID>)
    case rename(to: SpaceName, by: UserID)
    case makeGroup(GroupID, Permissions, by: UserID)
    case setPermissions(GroupID, Permissions, by: UserID)
    case removeGroup(GroupID, by: UserID)
    /// `person`, one of its members, is in exactly `inGroups` from now on.
    case place(UserID, inGroups: NonEmptySet<GroupID>, by: UserID)
    case makeAdmin(UserID, by: UserID)
    case removeAdmin(UserID, by: UserID)
    case addBot(Bot, by: UserID)
    case changeBot(Bot, by: UserID)
    case removeBot(BotID, by: UserID)
    case chooseMain(BotID, by: UserID)
    case addConnection(Connection, by: UserID)
    case changeConnection(Connection, by: UserID)
    case removeConnection(ConnectionID, by: UserID)
    case invite(SpaceInvite)
    case takeBack(SpaceInviteID, by: UserID)
    /// `person` joins with the invite whose token hashes to `hash`, at `now`.
    case join(with: SpaceInviteHash, as: UserID, at: Date)
    case leave(UserID)
    case archive(by: UserID)
    case unarchive(by: UserID)
    /// `asker` asks, for `person`, to run exactly `request`, which their scope doesn't allow.
    case ask(ExactRequest, by: UserID, as: Asker, id: AccessRequestID)
    /// `person` answers the request `id`: only someone who may decide for what it asks counts.
    case answer(AccessRequestID, AccessAnswer, by: UserID)
}

/// A space a person is in, as their list shows it: what it's called, whether it's in use, and
/// what they may do in it.
public struct SpaceListing: Hashable, Codable, Sendable {
    public let id: SpaceID
    public let name: SpaceName
    public let status: SpaceStatus
    public let permissions: Permissions

    public init(id: SpaceID, name: SpaceName, status: SpaceStatus, permissions: Permissions) {
        self.id = id
        self.name = name
        self.status = status
        self.permissions = permissions
    }
}

/// Why a space didn't do what it was asked.
public enum SpaceRefusal: Error, Equatable, Codable, Sendable, CustomStringConvertible {
    /// It's made already.
    case alreadyMade
    /// It isn't made yet.
    case notMadeYet
    /// A guest neither makes a space nor joins one.
    case guestsStayOut
    /// Whoever asked may not do that here.
    case notAllowed
    /// They're not in it.
    case notInIt
    /// They're its last admin: someone else has to be one first.
    case lastAdmin
    /// It has no group by that name.
    case noSuchGroup(GroupID)
    /// It has a group by that name already.
    case groupExists(GroupID)
    /// Its members group stays: whoever joins it is in it.
    case membersGroupStays
    /// The guests group stays: a guest coming into the space is in it.
    case guestsGroupStays
    /// Someone is in that group and no other: they're placed in another first.
    case someoneIsOnlyIn(GroupID)
    /// They're one of its admins, who are in every group.
    case anAdmin
    /// It has no bot like that.
    case noSuchBot(BotID)
    /// It has that bot already.
    case botExists(BotID)
    /// Its main bot stays: another is chosen as main first.
    case mainBotStays
    /// It has no connection like that.
    case noSuchConnection(ConnectionID)
    /// It has that connection already.
    case connectionExists(ConnectionID)
    /// No invite like it works: it was used, taken back, or ran out, or there never was one.
    case inviteDoesNotWork
    /// It's archived: it's read, and nothing new happens in it.
    case archived

    public var description: String {
        switch self {
        case .alreadyMade: "This space is made already."
        case .notMadeYet: "This space isn't made yet."
        case .guestsStayOut: "A guest can't make or join a space: sign in first."
        case .notAllowed: "You're not allowed to do that in this space."
        case .notInIt: "You're not in this space."
        case .lastAdmin: "You're its last admin: make someone else an admin first."
        case .noSuchGroup(let group): "This space has no group called \(group)."
        case .groupExists(let group): "This space has a group called \(group) already."
        case .membersGroupStays: "The members group stays: whoever joins the space is in it."
        case .guestsGroupStays: "The guests group stays: a guest coming into the space is in it."
        case .someoneIsOnlyIn(let group): "Someone is in \(group) and no other group: place them in another first."
        case .anAdmin: "They're an admin: admins are in every group."
        case .noSuchBot: "This space has no such bot."
        case .botExists: "This space has that bot already."
        case .mainBotStays: "The main bot stays: choose another as main first."
        case .noSuchConnection: "This space has no such connection."
        case .connectionExists: "This space has that connection already."
        case .inviteDoesNotWork: "This invite doesn't work: it's been used, taken back, or has run out."
        case .archived: "This space is archived: what's in it can be read, and nothing new happens in it."
        }
    }
}

/// A space through its life: before it's made, in use, or archived. What each holds is what it
/// can do: only making works before it's made.
public enum SpaceState: Hashable, Codable, Sendable {
    /// Nothing has happened to it yet: what its events fold from.
    case empty(SpaceID)
    case active(Space)
    /// Kept to be read: nothing new happens in it.
    case archived(Space)

    public var id: SpaceID {
        switch self {
        case .empty(let id): id
        case .active(let space), .archived(let space): space.id
        }
    }

    /// It, once it's made.
    public var space: Space? {
        switch self {
        case .empty: nil
        case .active(let space), .archived(let space): space
        }
    }

    /// Whether it's in use, once it's made.
    public var status: SpaceStatus? {
        switch self {
        case .empty: nil
        case .active: .active
        case .archived: .archived
        }
    }

    /// It as `person`'s list shows it: none before it's made, or when they're not in it.
    public func listing(for person: UserID) -> SpaceListing? {
        guard let space, let status, let permissions = space.permissions(of: person) else { return nil }
        return SpaceListing(
            id: space.id, name: space.name, status: status, permissions: permissions)
    }
}

extension SpaceState {
    /// A made space: its admins, who may do everything in it; its members, each in some of its
    /// groups; its groups, each with what it may; who may run each exact request it decides; and
    /// what's asked of it until it's answered.
    public struct Space: Hashable, Codable, Sendable {
        public let id: SpaceID
        public fileprivate(set) var name: SpaceName
        /// Who decides for it: never no one.
        public fileprivate(set) var admins: NonEmptySet<UserID>
        /// Everyone else in it, each with the groups they're in.
        public fileprivate(set) var members: [UserID: NonEmptySet<GroupID>]
        /// Its groups, each with what it may.
        public fileprivate(set) var groups: [GroupID: Permissions]
        /// Its bots: never none, one of them its main.
        public fileprivate(set) var bots: Bots
        /// Its ways in from platforms, by id.
        public fileprivate(set) var connections: [ConnectionID: Connection]
        /// The invites made that aren't spent, by id.
        public fileprivate(set) var invites: [SpaceInviteID: SpaceInvite]
        /// What each exact request it decided allows; the rest are its deciders' alone.
        public fileprivate(set) var access: [ExactRequest: Access]
        /// What's asked of it: waiting for an answer, or allowed once and not yet run.
        public fileprivate(set) var requests: [AccessRequestID: AccessRequest]
        /// Who asked each: the one what it allows once goes to.
        public fileprivate(set) var askers: [AccessRequestID: Asker]

        fileprivate init(
            id: SpaceID, name: SpaceName, admins: NonEmptySet<UserID>, groups: [GroupID: Permissions], main: Bot
        ) {
            self.id = id
            self.name = name
            self.admins = admins
            self.members = [:]
            self.groups = groups
            self.bots = Bots(main: main)
            self.connections = [:]
            self.invites = [:]
            self.access = [:]
            self.requests = [:]
            self.askers = [:]
        }

        /// What `person` may do here: everything for an admin, what their groups may for anyone else,
        /// and none when they're not in it.
        public func permissions(of person: UserID) -> Permissions? {
            if admins.contains(person) { return .all }
            return members[person].map { $0.elements.compactMap { groups[$0] }.reduce(.none) { $0.union($1) } }
        }

        /// Whether `person` is in it: one of its admins, or of its members.
        public func has(_ person: UserID) -> Bool {
            admins.contains(person) || members[person] != nil
        }

        /// The groups whatever's shared with a group reaches `person` through: an admin's are all of
        /// them.
        public func groupsReaching(_ person: UserID) -> Set<GroupID> {
            admins.contains(person) ? Set(groups.keys) : members[person]?.elements ?? []
        }

        /// Who's in it, each with the groups they're in, as `person`, one of them who may see its
        /// people, sees them: guests aren't among them.
        public func people(for person: UserID) throws(SpaceRefusal) -> [UserID: Set<GroupID>] {
            guard let permissions = permissions(of: person) else { throw .notInIt }
            guard permissions.people != nil else { throw .notAllowed }
            let everyone = admins.elements.union(members.keys).filter { !$0.isGuest }
            return Dictionary(uniqueKeysWithValues: everyone.map { ($0, groupsReaching($0)) })
        }

        /// Whom a call `person` makes here is on behalf of: them, in this space, with what they may
        /// do in it, the groups they're in, and the exact requests shared with them. Refused when
        /// they're not in it.
        public func scope(of person: UserID) throws(SpaceRefusal) -> CallScope {
            guard let permissions = permissions(of: person) else { throw .notInIt }
            let groups = groupsReaching(person)
            let asThem = CallScope(person, in: id, may: permissions, groups: groups, allowed: [])
            let shared = access.filter { $0.value.allows(asThem, .read) }.keys
            return CallScope(person, in: id, may: permissions, groups: groups, allowed: Set(shared))
        }

        /// The scope of a chain `person` starts here for `asker`, as it opens: theirs, with what was
        /// allowed `asker` once besides, which opening it spends. What another asked for, even for
        /// them, it doesn't take.
        public func opening(scopeOf person: UserID, for asker: Asker) throws(SpaceRefusal) -> (CallScope, [SpaceEvent])
        {
            let scope = try scope(of: person)
            let once = requests.values.filter {
                $0.by == person && askers[$0.id] == asker && $0.standing == .allowedOnce
            }
            .sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
            return (
                CallScope(
                    person, in: id, may: scope.permissions, groups: scope.groups,
                    allowed: scope.allowed.union(once.map(\.request))),
                once.map { .spent($0.id) }
            )
        }

        /// How exactly `request`, which `person` makes as `asker`, is decided now: allowed by what
        /// they may do and what's shared with them, allowed once for exactly that asker (the
        /// allowance to spend), or not at all. Refused when they're not in it.
        public func deciding(_ request: ExactRequest, for person: UserID, asker: Asker) throws(SpaceRefusal)
            -> RequestAllowance
        {
            if try scope(of: person).allows(request) { return .allowed }
            let once = requests.values.first {
                $0.by == person && askers[$0.id] == asker && $0.standing == .allowedOnce && $0.request == request
            }
            return once.map { .allowedOnce($0.id) } ?? .notAllowed
        }

        /// The invites that still work at `now`, the earliest made first.
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

        /// Whether `person` may do what `allows` says with what they may.
        fileprivate func check(_ person: UserID, _ allows: (Permissions) -> Bool) throws(SpaceRefusal) {
            guard let permissions = permissions(of: person) else { throw .notInIt }
            guard allows(permissions) else { throw .notAllowed }
        }
    }
}

/// A space's bots: never none, one of them its main.
public struct Bots: Hashable, Codable, Sendable {
    /// The one that answers when no other is asked for, or the one asked for is gone.
    public fileprivate(set) var main: Bot
    public fileprivate(set) var others: [BotID: Bot]

    fileprivate init(main: Bot) {
        self.main = main
        self.others = [:]
    }

    /// The bot `id` names, when it has it.
    public subscript(id: BotID) -> Bot? {
        id == main.id ? main : others[id]
    }

    /// All of them, the main first.
    public var all: [Bot] {
        [main] + others.values.sorted { $0.name.rawValue < $1.name.rawValue }
    }
}

/// What a space does: from a command and its state, what happens, or why it won't; and from what
/// happened, its state. Deciding never changes it; evolving never refuses.
public enum SpaceDecider {
    /// A space nothing has happened to yet.
    public static func initial(_ id: SpaceID) -> SpaceState {
        .empty(id)
    }

    /// What happens when `state` is asked to do `command`.
    public static func decide(_ command: SpaceCommand, _ state: SpaceState) throws(SpaceRefusal) -> [SpaceEvent] {
        switch state {
        case .empty: try deciding(command, unmade: state.id)
        case .active(let space): try deciding(command, in: space, archived: false)
        case .archived(let space): try deciding(command, in: space, archived: true)
        }
    }

    /// `state` after `event`: the one place it changes.
    public static func evolve(_ state: SpaceState, _ event: SpaceEvent) -> SpaceState {
        switch (state, event) {
        case (.empty(let id), .made(let name, let admins, let groups, let main)):
            .active(SpaceState.Space(id: id, name: name, admins: admins, groups: groups, main: main))
        case (.empty, _):
            state
        case (.active(let space), .archived):
            .archived(space)
        case (.archived(let space), .unarchived):
            .active(space)
        case (.active(let space), _):
            .active(evolving(space, event))
        case (.archived(let space), _):
            .archived(evolving(space, event))
        }
    }

    /// The space after `events`, in order.
    public static func evolve(_ state: SpaceState, _ events: [SpaceEvent]) -> SpaceState {
        events.reduce(state, evolve)
    }

    // MARK: Deciding

    private static func deciding(_ command: SpaceCommand, unmade id: SpaceID) throws(SpaceRefusal) -> [SpaceEvent] {
        switch command {
        case .make(let name, let person, let bot):
            guard !person.isGuest else { throw .guestsStayOut }
            return [.made(name, admins: NonEmptySet(person), groups: [.members: .members, .guests: .none], main: bot)]
        case .makeForPlatform(let name, let admins, let groups, let bot):
            return [
                .made(
                    name, admins: admins,
                    groups: groups.merging([.members: .members, .guests: .none]) { made, _ in made }, main: bot)
            ]
        default:
            throw .notMadeYet
        }
    }

    private static func deciding(_ command: SpaceCommand, in space: SpaceState.Space, archived: Bool)
        throws(SpaceRefusal)
        -> [SpaceEvent]
    {
        switch command {
        case .make, .makeForPlatform:
            throw .alreadyMade
        case .setAdmins(let admins):
            return having(space, admins: admins.elements)
        case .admit(let person, let groups):
            guard !space.has(person) else { return [] }
            if let unknown = groups.elements.first(where: { space.groups[$0] == nil }) { throw .noSuchGroup(unknown) }
            return [.joined(person, inGroups: groups)]
        case .rename(let name, let person):
            try space.check(person) { $0.configureSpace }
            return name == space.name ? [] : [.named(name)]
        case .makeGroup(let group, let permissions, let person):
            try space.check(person) { $0.configureSpace }
            guard space.groups[group] == nil else { throw .groupExists(group) }
            return [.groupMade(group, permissions)]
        case .setPermissions(let group, let permissions, let person):
            try space.check(person) { $0.configureSpace }
            guard let current = space.groups[group] else { throw .noSuchGroup(group) }
            return current == permissions ? [] : [.permissionsSet(group, permissions)]
        case .removeGroup(let group, let person):
            try space.check(person) { $0.configureSpace }
            guard group != .members else { throw .membersGroupStays }
            guard group != .guests else { throw .guestsGroupStays }
            guard space.groups[group] != nil else { return [] }
            guard !space.members.values.contains(NonEmptySet(group)) else { throw .someoneIsOnlyIn(group) }
            return [.groupRemoved(group)]
        case .place(let person, let groups, let placer):
            try space.check(placer) { $0.people == .manage }
            guard !space.admins.contains(person) else { throw .anAdmin }
            guard let current = space.members[person] else { throw .notInIt }
            if let unknown = groups.elements.first(where: { space.groups[$0] == nil }) { throw .noSuchGroup(unknown) }
            return current == groups ? [] : [.placed(person, inGroups: groups)]
        case .makeAdmin(let person, let maker):
            try space.check(maker) { $0.configureSpace }
            guard space.has(person) else { throw .notInIt }
            return space.admins.contains(person) ? [] : [.adminMade(person)]
        case .removeAdmin(let person, let remover):
            try space.check(remover) { $0.configureSpace }
            return try steppingDown(space, person)
        case .addBot(let bot, let person):
            try space.check(person) { $0.bots == .configure }
            guard space.bots[bot.id] == nil else { throw .botExists(bot.id) }
            return [.botAdded(bot)]
        case .changeBot(let bot, let person):
            try space.check(person) { $0.bots == .configure }
            guard let current = space.bots[bot.id] else { throw .noSuchBot(bot.id) }
            return current == bot ? [] : [.botChanged(bot)]
        case .removeBot(let id, let person):
            try space.check(person) { $0.bots == .configure }
            guard id != space.bots.main.id else { throw .mainBotStays }
            return space.bots[id] == nil ? [] : [.botRemoved(id)]
        case .chooseMain(let id, let person):
            try space.check(person) { $0.bots == .configure }
            guard space.bots[id] != nil else { throw .noSuchBot(id) }
            return id == space.bots.main.id ? [] : [.mainChosen(id)]
        case .addConnection(let connection, let person):
            try space.check(person) { $0.connections }
            guard space.connections[connection.id] == nil else { throw .connectionExists(connection.id) }
            return [.connectionAdded(connection)]
        case .changeConnection(let connection, let person):
            try space.check(person) { $0.connections }
            guard let current = space.connections[connection.id] else { throw .noSuchConnection(connection.id) }
            return current == connection ? [] : [.connectionChanged(connection)]
        case .removeConnection(let id, let person):
            try space.check(person) { $0.connections }
            return space.connections[id] == nil ? [] : [.connectionRemoved(id)]
        case .invite(let invite):
            try space.check(invite.by) { $0.people == .manage }
            guard !archived else { throw .archived }
            return [.invited(invite)]
        case .takeBack(let id, let person):
            try space.check(person) { $0.people == .manage }
            return space.invites[id] == nil ? [] : [.inviteTakenBack(id)]
        case .join(let hash, let person, let now):
            guard !person.isGuest else { throw .guestsStayOut }
            guard !archived else { throw .archived }
            guard let invite = space.invites.values.first(where: { $0.hash == hash }), invite.works(at: now) else {
                throw .inviteDoesNotWork
            }
            guard !space.has(person) else { return [] }
            return [.inviteUsed(invite.id, by: person), .joined(person, inGroups: NonEmptySet(.members))]
        case .leave(let person):
            guard space.has(person) else { throw .notInIt }
            guard !space.admins.contains(person) || space.admins.count > 1 else { throw .lastAdmin }
            return [.left(person)]
        case .archive(let person):
            try space.check(person) { $0.configureSpace }
            return archived ? [] : [.archived(by: person)]
        case .unarchive(let person):
            try space.check(person) { $0.configureSpace }
            return archived ? [.unarchived(by: person)] : []
        case .ask(let request, let person, let asker, let id):
            guard space.request(for: request, by: person, as: asker) == nil,
                try !space.scope(of: person).allows(request)
            else { return [] }
            return [.asked(AccessRequest(id: id, request: request, by: person, standing: .waiting), by: asker)]
        case .answer(let id, let answer, let person):
            // An answer by someone who isn't in it, or who may not decide for what it asks, doesn't count.
            guard let open = space.requests[id], open.standing == .waiting, let scope = try? space.scope(of: person),
                space.access(to: open.request).allows(scope, .write)
            else { return [] }
            return [.answered(id, answer, by: person)]
        }
    }

    /// Its admins becoming exactly `admins`: each who isn't one is made one; then each who's no
    /// longer one steps down into the members group.
    private static func having(_ space: SpaceState.Space, admins: Set<UserID>) -> [SpaceEvent] {
        guard !admins.isEmpty else { return [] }
        let making = admins.subtracting(space.admins.elements).sorted { $0.key < $1.key }.map(SpaceEvent.adminMade)
        let stepping = space.admins.elements.subtracting(admins).sorted { $0.key < $1.key }
            .map { SpaceEvent.adminSteppedDown($0, inGroups: NonEmptySet(.members)) }
        return making + stepping
    }

    /// `person` no longer one of its admins, into the members group: refused for its last admin.
    private static func steppingDown(_ space: SpaceState.Space, _ person: UserID) throws(SpaceRefusal) -> [SpaceEvent] {
        guard space.admins.contains(person) else { return [] }
        guard space.admins.count > 1 else { throw .lastAdmin }
        return [.adminSteppedDown(person, inGroups: NonEmptySet(.members))]
    }

    // MARK: Evolving

    private static func evolving(_ space: SpaceState.Space, _ event: SpaceEvent) -> SpaceState.Space {
        var next = space
        switch event {
        case .made, .archived, .unarchived:
            break
        case .named(let name):
            next.name = name
        case .joined(let person, let groups), .placed(let person, let groups):
            next.members[person] = groups
        case .left(let person):
            next.members[person] = nil
            // Its last admin never leaves: deciding refuses it.
            next.admins = space.admins.removing(person) ?? space.admins
        case .adminMade(let person):
            next.admins = space.admins.inserting(person)
            next.members[person] = nil
        case .adminSteppedDown(let person, let groups):
            // Its last admin never steps down: deciding refuses it.
            next.admins = space.admins.removing(person) ?? space.admins
            next.members[person] = groups
        case .botAdded(let bot):
            next.bots.others[bot.id] = bot
        case .botChanged(let bot):
            if bot.id == space.bots.main.id { next.bots.main = bot } else { next.bots.others[bot.id] = bot }
        case .botRemoved(let id):
            // Never the main: deciding refuses it.
            next.bots.others[id] = nil
        case .mainChosen(let id):
            // One of its others: deciding says so.
            guard let chosen = space.bots.others[id] else { return next }
            next.bots.others[id] = nil
            next.bots.others[space.bots.main.id] = space.bots.main
            next.bots.main = chosen
        case .connectionAdded(let connection), .connectionChanged(let connection):
            next.connections[connection.id] = connection
        case .connectionRemoved(let id):
            next.connections[id] = nil
        case .groupMade(let group, let permissions), .permissionsSet(let group, let permissions):
            next.groups[group] = permissions
        case .groupRemoved(let group):
            next.groups[group] = nil
            // No one is in it alone: deciding refuses that.
            next.members = space.members.compactMapValues { $0.removing(group) }
        case .asked(let request, let asker):
            next.requests[request.id] = request
            next.askers[request.id] = asker
        case .answered(let id, let answer, _):
            guard let open = space.requests[id] else { return next }
            if answer != .once { next.askers[id] = nil }
            switch answer {
            case .once:
                next.requests[id] = open.standing(.allowedOnce)
            case .always:
                next.requests[id] = nil
                next.access[open.request] = space.access(to: open.request).sharing(with: .person(open.by), .read)
            case .everyone:
                // Everyone in the groups whoever asked is in.
                next.requests[id] = nil
                next.access[open.request] = space.groupsReaching(open.by).reduce(space.access(to: open.request)) {
                    $0.sharing(with: .group(space.id, $1), .read)
                }
            case .no:
                next.requests[id] = nil
            }
        case .spent(let id):
            next.requests[id] = nil
            next.askers[id] = nil
        case .invited(let invite):
            next.invites[invite.id] = invite
        case .inviteUsed(let id, _), .inviteTakenBack(let id):
            next.invites[id] = nil
        }
        return next
    }
}

/// How exactly a request is decided in a space now.
public enum RequestAllowance: Hashable, Sendable {
    /// What its person may do, or what's shared with them, allows it.
    case allowed
    /// It's allowed once for exactly whoever asks: the allowance this spends.
    case allowedOnce(AccessRequestID)
    case notAllowed
}
