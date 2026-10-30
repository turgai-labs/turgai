#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Who a person is: the way they came into Turgai, each a person of their own. Two ways in that
/// are the same human are linked, never merged.
public enum UserID: Hashable, Codable, Sendable {
    /// Whoever signs in with the Turgai account `id`, wherever they use it.
    case account(UUID)
    /// The Telegram user `id`, whichever bot they write to.
    case telegram(Int64)
    /// A guest: someone no one signed in as, given an id of their own when they came, who's
    /// remembered by nothing.
    case guest(UUID)

    /// Its name for the actor and journal that keep what's theirs.
    public var key: String {
        switch self {
        case .account(let id): "account-\(id.uuidString)"
        case .telegram(let id): "telegram-\(id)"
        case .guest(let id): "guest-\(id.uuidString)"
        }
    }

    /// Whether it's a guest's.
    public var isGuest: Bool {
        if case .guest = self { true } else { false }
    }
}

/// The domain view of a Turgai user. Provider-specific profile data belongs in
/// a channel adapter or a separate profile projection.
public struct User: Hashable, Codable, Sendable {
    public let id: UserID

    public init(id: UserID) {
        self.id = id
    }
}
