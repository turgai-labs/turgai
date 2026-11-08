#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A space the signed-in person is in, as their list shows it: what it's called, and their role.
public struct SpaceSummary: Codable, Hashable, Sendable, Identifiable {
    public enum Role: String, Codable, Hashable, Sendable {
        case admin
        case member
    }

    public let id: String
    public let name: String
    public let role: Role

    public init(id: String, name: String, role: Role) {
        self.id = id
        self.name = name
        self.role = role
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
    public let spaceID: String
    public let token: String

    public init(spaceID: String, token: String) {
        self.spaceID = spaceID
        self.token = token
    }

    /// `written`, a link as it's pasted, its space around it aside: none when it isn't an invite's.
    public init?(_ written: String) {
        let words = written.split(whereSeparator: \.isWhitespace)
        guard words.count == 1, let link = words.first, link.hasPrefix(Self.prefix) else { return nil }
        let parts = link.dropFirst(Self.prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil, !parts[1].isEmpty else { return nil }
        self.init(spaceID: String(parts[0]), token: String(parts[1]))
    }

    public var description: String { Self.prefix + "\(spaceID)/\(token)" }

    private static let prefix = "turgai://join/"
}

/// Joining a space with the token an invite's link carries.
public struct JoinSpaceRequest: Codable, Hashable, Sendable {
    public let token: String

    public init(token: String) {
        self.token = token
    }
}
