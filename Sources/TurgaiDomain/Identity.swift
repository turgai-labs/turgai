#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Turgai's canonical identity for a person or other human-facing account.
///
/// The default initializer from `ParticipantID` gives every channel
/// participant a stable Turgai identity. A later, explicit identity-linking
/// policy may map several participants to the same `UserID`.
public struct UserID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public init(participantID: ParticipantID) {
        self.init(rawValue: "participant:\(participantID.stableKey)")
    }

    /// The person who signs in with the Turgai account `id`: the same in every chat they have with
    /// it, with any bot, and on the dashboard.
    public init(account id: UUID) {
        self.init(rawValue: "account:\(id.uuidString)")
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

/// A known association between a Turgai user and one channel participant.
/// Keeping this explicit leaves room for consent-based cross-channel linking.
public struct UserParticipantLink: Hashable, Codable, Sendable {
    public let userID: UserID
    public let participantID: ParticipantID

    public init(userID: UserID, participantID: ParticipantID) {
        self.userID = userID
        self.participantID = participantID
    }
}
