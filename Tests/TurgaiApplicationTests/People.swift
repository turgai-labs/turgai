import TurgaiDomain

/// The people the tests are about, each a Telegram user of their own.
extension UserID {
    static let ann = UserID.telegram(1)
    static let bob = UserID.telegram(2)
    static let kid = UserID.telegram(3)
    static let dad = UserID.telegram(4)
    static let mom = UserID.telegram(5)
    static let cat = UserID.telegram(6)
    static let tester = UserID.telegram(7)
}

/// Whom a test's calls are on behalf of, as a space settles it.
extension CallScope {
    /// `person` in `space` as one of its members: in its members group, with what that may.
    static func member(_ person: UserID, in space: SpaceID, allowed: Set<ExactRequest> = []) -> CallScope {
        CallScope(person, in: space, may: .members, groups: [.members], allowed: allowed)
    }

    /// `person` in `space` as one of its admins: they may everything, and are in every group.
    static func admin(_ person: UserID, in space: SpaceID, allowed: Set<ExactRequest> = []) -> CallScope {
        CallScope(person, in: space, may: .all, groups: [.members], allowed: allowed)
    }
}
