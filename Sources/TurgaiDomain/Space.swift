#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Whether a space is in use. Archived, it's kept to be read, and nothing new happens in it.
public enum SpaceStatus: String, Hashable, Codable, Sendable {
    case active
    case archived
}

/// A group of a space's people, by the name the space gave it: unique in its space, and never
/// changed, so whatever's shared with it stays shared with it.
public struct GroupID: Hashable, Codable, Sendable, CustomStringConvertible {
    public static let maximumLength = 80

    public let rawValue: String

    /// The group `written` names, without the space around it: none when there's nothing, or too much.
    public init?(_ written: String) {
        let name = written.trimmed()
        guard !name.isEmpty, name.count <= Self.maximumLength else { return nil }
        self.rawValue = name
    }

    private init(known name: String) {
        self.rawValue = name
    }

    /// The group every space is made with, which whoever joins it is in.
    public static let members = GroupID(known: "members")
    /// The group every space is made with, which a guest coming into it is in: allowed nothing,
    /// unless its admins allow the group something.
    public static let guests = GroupID(known: "guests")

    public var description: String { rawValue }
}

/// What may be done in a space: in each of its parts, how far, or nothing at all.
public struct Permissions: Hashable, Codable, Sendable {
    /// Its people: seeing who's in it, or also managing them: inviting, removing, placing in groups.
    public enum People: Int, Hashable, Codable, Sendable, Comparable {
        case see, manage
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Its bots: using them, or also configuring them.
    public enum Bots: Int, Hashable, Codable, Sendable, Comparable {
        case use, configure
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What's asked of it: answering, or also running any exact request without asking.
    public enum Requests: Int, Hashable, Codable, Sendable, Comparable {
        case answer, runAny
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The tasks kept in it: seeing everyone's, or also changing them.
    public enum Tasks: Int, Hashable, Codable, Sendable, Comparable {
        case see, manage
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var people: People?
    public var bots: Bots?
    public var requests: Requests?
    public var tasks: Tasks?
    /// Configuring its connections.
    public var connections: Bool
    /// Deleting anyone's conversation in it.
    public var deleteConversations: Bool
    /// Naming and archiving it, and making its groups, what they may do, and its admins.
    public var configureSpace: Bool

    public init(
        people: People? = nil, bots: Bots? = nil, requests: Requests? = nil, tasks: Tasks? = nil,
        connections: Bool = false, deleteConversations: Bool = false, configureSpace: Bool = false
    ) {
        self.people = people
        self.bots = bots
        self.requests = requests
        self.tasks = tasks
        self.connections = connections
        self.deleteConversations = deleteConversations
        self.configureSpace = configureSpace
    }

    /// Nothing at all: taking part only in one's own conversations.
    public static let none = Permissions()

    /// Everything: what a space's admins may.
    public static let all = Permissions(
        people: .manage, bots: .configure, requests: .runAny, tasks: .manage, connections: true,
        deleteConversations: true, configureSpace: true)

    /// What whoever's in the members group may, as a space is made: see its people and use its bots.
    public static let members = Permissions(people: .see, bots: .use)

    /// Everything either may: in each part, the further of the two. How several groups add up.
    public func union(_ other: Permissions) -> Permissions {
        func further<Level: Comparable>(_ one: Level?, _ another: Level?) -> Level? {
            switch (one, another) {
            case (let one?, let another?): Swift.max(one, another)
            case (let one?, nil): one
            case (nil, let another): another
            }
        }
        return Permissions(
            people: further(people, other.people), bots: further(bots, other.bots),
            requests: further(requests, other.requests), tasks: further(tasks, other.tasks),
            connections: connections || other.connections,
            deleteConversations: deleteConversations || other.deleteConversations,
            configureSpace: configureSpace || other.configureSpace)
    }
}

/// A set with one element at least.
public struct NonEmptySet<Element: Hashable & Sendable>: Hashable, Sendable {
    public private(set) var elements: Set<Element>

    /// `first`, and `rest` besides.
    public init(_ first: Element, _ rest: Set<Element> = []) {
        elements = rest.union([first])
    }

    /// `elements`, unless there are none.
    public init?(_ elements: Set<Element>) {
        guard !elements.isEmpty else { return nil }
        self.elements = elements
    }

    public func contains(_ element: Element) -> Bool { elements.contains(element) }
    public var count: Int { elements.count }

    /// With `element` too.
    public func inserting(_ element: Element) -> Self {
        var next = self
        next.elements.insert(element)
        return next
    }

    /// Without `element`: none when it was the only one.
    public func removing(_ element: Element) -> Self? {
        Self(elements.subtracting([element]))
    }
}

extension NonEmptySet: Codable where Element: Codable {
    public init(from decoder: any Decoder) throws {
        let elements = try decoder.singleValueContainer().decode(Set<Element>.self)
        guard let set = Self(elements) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "An empty set"))
        }
        self = set
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(elements)
    }
}

/// A space's own identity: minted when the space is made, and only ever given by whoever holds it,
/// never worked out from anything else.
public struct SpaceID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// What a space is called, as the people who made it named it: some words, at most 80 letters.
public struct SpaceName: Hashable, Codable, Sendable, CustomStringConvertible {
    public static let maximumLength = 80

    public let rawValue: String

    /// The name `written`, without the space around it: none when there's nothing, or too much.
    public init?(_ written: String) {
        let name = written.trimmed()
        guard !name.isEmpty, name.count <= Self.maximumLength else { return nil }
        self.rawValue = name
    }

    public var description: String { rawValue }
}

public struct SpaceInviteID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// An invite's token as a space keeps it: only its hash, so nothing kept lets anyone in.
public struct SpaceInviteHash: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// How long an invite works, as whoever made it chose: until it's used, or until a time.
public enum SpaceInviteLifetime: Hashable, Codable, Sendable {
    case untilUsed
    case until(Date)
}

/// An open invite to a space: one person's way in, once.
public struct SpaceInvite: Hashable, Codable, Sendable {
    public let id: SpaceInviteID
    public let hash: SpaceInviteHash
    /// The admin who made it.
    public let by: UserID
    public let lifetime: SpaceInviteLifetime

    public init(id: SpaceInviteID = SpaceInviteID(), hash: SpaceInviteHash, by: UserID, lifetime: SpaceInviteLifetime) {
        self.id = id
        self.hash = hash
        self.by = by
        self.lifetime = lifetime
    }

    /// Whether it still works at `now`.
    public func works(at now: Date) -> Bool {
        switch lifetime {
        case .untilUsed: true
        case .until(let end): now < end
        }
    }
}

/// Who a piece of work is for, and what they may do: whoever asked, one of a space's people or one
/// of its own actors, in that space, with what they may do there, the groups they're in, and the
/// exact requests it shares with them, as the space says when the work starts. Everything the work
/// calls has them, and nothing keeps them after it.
public struct CallScope: Hashable, Codable, Sendable {
    public let asker: Party
    public let space: SpaceID
    public let permissions: Permissions
    /// The groups they're in, whom what's shared with a group reaches: an admin is in every one.
    public let groups: Set<GroupID>
    /// The exact requests they may run in it besides any, when they may run any: those shared
    /// with them, and those allowed once for this scope.
    public let allowed: Set<ExactRequest>

    /// The person who asked, when a person did.
    public var person: UserID? { asker.person }

    public init(
        _ person: UserID, in space: SpaceID, may permissions: Permissions, groups: Set<GroupID>,
        allowed: Set<ExactRequest>
    ) {
        self.init(.person(person), in: space, may: permissions, groups: groups, allowed: allowed)
    }

    public init(
        _ asker: Party, in space: SpaceID, may permissions: Permissions, groups: Set<GroupID>,
        allowed: Set<ExactRequest>
    ) {
        self.asker = asker
        self.space = space
        self.permissions = permissions
        self.groups = groups
        self.allowed = allowed
    }

    /// Whether exactly `request` runs in this scope: anyone's who may run any, and anyone's it's
    /// allowed.
    public func allows(_ request: ExactRequest) -> Bool {
        permissions.requests == .runAny || allowed.contains(request)
    }
}
