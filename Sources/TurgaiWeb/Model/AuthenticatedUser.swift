import Foundation
import TurgaiDomain

struct AccountInfo: Identifiable, Sendable, Equatable {
    let id: UUID
    let username: String
}

enum AccountRole: String, Sendable, Equatable {
    case user
    case administrator
    case member
}

enum AccountStatus: String, Sendable, Equatable {
    case pending
    case approved
    case disabled
}

enum AccountAction: String, Sendable, Equatable {
    case approve
    case enable
    case disable
    case administrator
    case member
    case user
}

struct AccountSummary: Identifiable, Sendable, Equatable {
    let info: AccountInfo
    let role: AccountRole
    let status: AccountStatus

    var id: UUID { info.id }
    var username: String { info.username }
}

enum AuthenticatedUser: Identifiable, Sendable, Equatable {
    case user(AccountInfo)
    case member(AccountInfo)
    case administrator(AccountInfo)

    var id: UUID {
        switch self {
        case .user(let account): account.id
        case .member(let account), .administrator(let account): account.id
        }
    }

    var username: String {
        switch self {
        case .user(let account): account.username
        case .member(let account), .administrator(let account): account.username
        }
    }

    /// The account in the dashboard's group, as the accounts say: an admin when it's an
    /// administrator. Its group settles whom what the dashboard asks for is on behalf of.
    var dashboardMembership: Membership {
        Membership(UserID(account: id), as: { if case .administrator = self { .admin } else { .member } }())
    }

}
