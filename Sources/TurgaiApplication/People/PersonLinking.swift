import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum PersonLinkingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A guest stays a guest: they link to no one.
    case guestsDontLink
    /// No code like it is waiting: it was mistyped, it's been used, or its time is up.
    case codeDoesNotWork

    public var description: String {
        switch self {
        case .guestsDontLink: "A guest can't link to anyone: sign in first."
        case .codeDoesNotWork: "That code doesn't work; ask for a new one."
        }
    }
}

/// Saying two persons are the same human: one asks for a code, the other enters it. Each code works
/// once, for a while, and lives only as long as this does.
public actor PersonLinking {
    /// How long a code works.
    public static let codeLifetime: TimeInterval = 600

    private let storage: PersonLinkStorage
    /// The codes waiting to be entered: whose each is, and until when it works.
    private var codes: [LinkCode: (person: UserID, until: Date)] = [:]

    public init(storage: PersonLinkStorage) {
        self.storage = storage
    }

    /// A code for `person` to enter as their other way in: it replaces one they asked for before.
    public func code(for person: UserID, now: Date = Date()) throws(PersonLinkingError) -> LinkCode {
        guard !person.isGuest else { throw .guestsDontLink }
        codes = codes.filter { $0.value.until > now && $0.value.person != person }
        var code = LinkCode.random()
        while codes[code] != nil { code = LinkCode.random() }
        codes[code] = (person, now.addingTimeInterval(Self.codeLifetime))
        return code
    }

    /// Links `person` with whoever asked for `code`, which is then used up: who that is.
    public func link(_ person: UserID, using code: LinkCode, now: Date = Date()) async throws -> UserID {
        guard !person.isGuest else { throw PersonLinkingError.guestsDontLink }
        guard let waiting = codes.removeValue(forKey: code), waiting.until > now else {
            throw PersonLinkingError.codeDoesNotWork
        }
        // Their own code says nothing new.
        if waiting.person != person { try await storage.link(person, waiting.person) }
        return waiting.person
    }

    /// Ends the link between `person` and `other`: both go on as they were.
    public func unlink(_ person: UserID, from other: UserID) async throws {
        try await storage.unlink(person, other)
    }

    /// Everyone `person` is the same human as, through any chain of links.
    public func linked(to person: UserID) async throws -> [UserID] {
        try await storage.linked(person)
    }

    /// The persons `person` linked with themselves, as their settings list them.
    public func pairedWith(_ person: UserID) async throws -> [UserID] {
        try await storage.pairedWith(person)
    }
}
