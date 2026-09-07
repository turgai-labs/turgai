#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Norby's canonical identity for a person or other human-facing account.
///
/// The default initializer from `ParticipantID` gives every channel
/// participant a stable Norby identity. A later, explicit identity-linking
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
}

/// The domain view of a Norby user. Provider-specific profile data belongs in
/// a channel adapter or a separate profile projection.
public struct User: Hashable, Codable, Sendable {
    public let id: UserID

    public init(id: UserID) {
        self.id = id
    }
}

/// A known association between a Norby user and one channel participant.
/// Keeping this explicit leaves room for consent-based cross-channel linking.
public struct UserParticipantLink: Hashable, Codable, Sendable {
    public let userID: UserID
    public let participantID: ParticipantID

    public init(userID: UserID, participantID: ParticipantID) {
        self.userID = userID
        self.participantID = participantID
    }
}
