#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Another way in that's the signed-in person too: their Turgai account, or a Telegram user.
public struct LinkedPerson: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case account
        case telegram
    }

    /// The person as the API names them, to unlink them by.
    public let id: String
    public let kind: Kind
    /// The Telegram user it is, for a Telegram user.
    public let telegramUserID: Int64?

    public init(id: String, kind: Kind, telegramUserID: Int64?) {
        self.id = id
        self.kind = kind
        self.telegramUserID = telegramUserID
    }
}

/// A code for the signed-in person to enter as their other way in: `/link K7Q-4P2` to the
/// Telegram bot.
public struct LinkCodeOffer: Codable, Hashable, Sendable {
    public let code: String
    /// When it stops working.
    public let expiresAt: Date

    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }
}

/// A code the signed-in person got on their other way in, to enter here.
public struct EnterLinkCodeRequest: Codable, Hashable, Sendable {
    public let code: String

    public init(code: String) {
        self.code = code
    }
}
