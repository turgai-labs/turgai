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

    /// The person `key` names, as ``key`` writes them: refused when it names none.
    public init(key: String) throws(UserIDError) {
        let parts = key.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw .notAPerson(key) }
        switch parts[0] {
        case "account":
            guard let id = UUID(uuidString: parts[1]) else { throw .notAPerson(key) }
            self = .account(id)
        case "telegram":
            guard let id = Int64(parts[1]) else { throw .notAPerson(key) }
            self = .telegram(id)
        case "guest":
            guard let id = UUID(uuidString: parts[1]) else { throw .notAPerson(key) }
            self = .guest(id)
        default:
            throw .notAPerson(key)
        }
    }
}

public enum UserIDError: Error, Equatable, Sendable {
    /// The text names no person.
    case notAPerson(String)
}

/// The domain view of a Turgai user. Provider-specific profile data belongs in
/// a channel adapter or a separate profile projection.
public struct User: Hashable, Codable, Sendable {
    public let id: UserID

    public init(id: UserID) {
        self.id = id
    }
}

/// What one way in shows for another to enter, to say they're the same human: six letters and
/// digits that can't be mistaken for each other, written `K7Q-4P2`.
public struct LinkCode: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The letters and digits a code is made of: none that reads as another.
    public static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    public let rawValue: String

    /// The code `written`, however it was typed: in any case, with or without its dash and spaces.
    public init?(_ written: String) {
        let letters = written.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard letters.count == 6, letters.allSatisfy(Self.alphabet.contains) else { return nil }
        self.rawValue = letters
    }

    /// A new code, at random.
    public static func random() -> Self {
        Self(String((0..<6).map { _ in alphabet.randomElement()! }))!
    }

    public var description: String {
        "\(rawValue.prefix(3))-\(rawValue.suffix(3))"
    }
}

/// What `/link` asks for: a new code to enter as one's other way in, or that a code given here be
/// entered.
public enum LinkAsk: Sendable, Equatable {
    case newCode
    case code(LinkCode)
    /// What was given isn't a code at all.
    case notACode(String)

    /// The ask `argument` makes: none asks for a new code.
    public init(_ argument: String?) {
        guard let argument, !argument.isEmpty else {
            self = .newCode
            return
        }
        self = LinkCode(argument).map(LinkAsk.code) ?? .notACode(argument)
    }
}
