import Foundation

struct AccountInfo: Identifiable, Sendable, Equatable {
    let id: UUID
    let username: String
}

enum AccountRole: String, Sendable, Equatable {
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
    case disable
    case administrator
    case member
}

struct AccountSummary: Identifiable, Sendable, Equatable {
    let info: AccountInfo
    let role: AccountRole
    let status: AccountStatus

    var id: UUID { info.id }
    var username: String { info.username }
}

enum AuthenticatedUser: Identifiable, Sendable, Equatable {
    case member(AccountInfo)
    case administrator(AccountInfo)

    var id: UUID {
        switch self {
        case .member(let account), .administrator(let account): account.id
        }
    }

    var username: String {
        switch self {
        case .member(let account), .administrator(let account): account.username
        }
    }
}
