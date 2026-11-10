#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The signed-in person: their id, and what they're called.
public struct Me: Codable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A space's id, as the API names it.
public struct SpaceID: Codable, Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A space the signed-in person is in, as their list shows it: what it's called, their role,
/// whether it's in use, and whose it is.
public struct SpaceSummary: Codable, Hashable, Sendable, Identifiable {
    public enum Role: String, Codable, Hashable, Sendable {
        case admin
        case member
    }

    /// Whether it's in use. Archived, what's in it is read, and nothing new happens in it.
    public enum Status: String, Codable, Hashable, Sendable {
        case active
        case archived
    }

    /// Whose it is: Turgai's own, where every account is and which stays in use, or one made.
    public enum Kind: String, Codable, Hashable, Sendable {
        case turgaisOwn
        case made
    }

    public let id: SpaceID
    public let name: String
    public let role: Role
    public let status: Status
    public let kind: Kind

    public init(id: SpaceID, name: String, role: Role, status: Status, kind: Kind) {
        self.id = id
        self.name = name
        self.role = role
        self.status = status
        self.kind = kind
    }
}

/// Someone in a space, as another of its people sees them: their id, what they're called, and their
/// role.
public struct SpacePerson: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let role: SpaceSummary.Role

    public init(id: String, name: String, role: SpaceSummary.Role) {
        self.id = id
        self.name = name
        self.role = role
    }
}

/// A new space, called `name`: the one who asks is its first admin.
public struct MakeSpaceRequest: Codable, Hashable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// A space called `name` from now on.
public struct RenameSpaceRequest: Codable, Hashable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// A new invite to a space: working for so many days, or until it's used when none are given.
public struct MakeInviteRequest: Codable, Hashable, Sendable {
    public let validForDays: Int?

    public init(validForDays: Int?) {
        self.validForDays = validForDays
    }
}

/// A new invite, once: the link to give one person, and the token in it, which no one keeps.
public struct SpaceInviteOffer: Codable, Hashable, Sendable {
    public let id: String
    public let token: String
    public let link: String
    /// When it stops working: none when it works until it's used.
    public let expiresAt: Date?

    public init(id: String, token: String, link: String, expiresAt: Date?) {
        self.id = id
        self.token = token
        self.link = link
        self.expiresAt = expiresAt
    }
}

/// An invite that still works, as its space's admins see it: never its token.
public struct SpaceInviteListing: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    /// When it stops working: none when it works until it's used.
    public let expiresAt: Date?

    public init(id: String, expiresAt: Date?) {
        self.id = id
        self.expiresAt = expiresAt
    }
}

/// An invite to a space, as its link writes it: `turgai://join/<space>/<token>`.
public struct SpaceInviteLink: Hashable, Sendable, CustomStringConvertible {
    public let spaceID: SpaceID
    public let token: String

    public init(spaceID: SpaceID, token: String) {
        self.spaceID = spaceID
        self.token = token
    }

    /// `written`, a link as it's pasted, its space around it aside: none when it isn't an invite's.
    public init?(_ written: String) {
        let words = written.split(whereSeparator: \.isWhitespace)
        guard words.count == 1, let link = words.first, link.hasPrefix(Self.prefix) else { return nil }
        let parts = link.dropFirst(Self.prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil, !parts[1].isEmpty else { return nil }
        self.init(spaceID: SpaceID(rawValue: String(parts[0])), token: String(parts[1]))
    }

    public var description: String { Self.prefix + "\(spaceID.rawValue)/\(token)" }

    private static let prefix = "turgai://join/"
}

/// Joining a space with the token an invite's link carries.
public struct JoinSpaceRequest: Codable, Hashable, Sendable {
    public let token: String

    public init(token: String) {
        self.token = token
    }
}
