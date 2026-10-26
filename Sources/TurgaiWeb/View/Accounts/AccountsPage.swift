import AnyLanguageModel
import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import NIOCore
import TurgaiApplication
import TurgaiHail
import TurgaiPersistence
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct AccountsPage: HTMLDocument, Sendable {
    let user: AuthenticatedUser
    let accounts: [AccountSummary]
    let error: String?

    init(user: AuthenticatedUser, accounts: [AccountSummary], error: String? = nil) {
        self.user = user
        self.accounts = accounts
        self.error = error
    }

    var title: String { "Turgai — Accounts" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("app-page")) {
            PageShell(
                kind: .private,
                header: PageHeader(user: user, navigation: .active(.accounts)),
                footer: PageFooter { EmptyFooterContent() }
            ) {
                section(.class("page-intro detail-page-intro")) {
                    div {
                        h1 { "Accounts" }
                        p(.class("lede")) { "Decide who can use this Turgai and what they can change." }
                    }
                }
                if let error { p(.class("error page-error")) { error } }
                section(.class("accounts-list"), .init(name: "aria-label", value: "Accounts")) {
                    for group in accountGroups where !group.accounts.isEmpty {
                        AccountGroup(title: group.title, accounts: group.accounts, currentUserID: user.id)
                    }
                }
            }
        }
    }

    /// The accounts by role, the disabled ones last whatever their role.
    private var accountGroups: [(title: String, accounts: [AccountSummary])] {
        func active(_ role: AccountRole) -> [AccountSummary] {
            accounts.filter { (account: AccountSummary) -> Bool in account.role == role && account.status != .disabled }
        }
        return [
            ("Administrators", active(.administrator)),
            ("Members", active(.member)),
            ("Users", active(.user)),
            ("Disabled", accounts.filter { (account: AccountSummary) -> Bool in account.status == .disabled }),
        ]
    }
}

/// One group of accounts, with how many there are.
private struct AccountGroup: HTML {
    let title: String
    let accounts: [AccountSummary]
    let currentUserID: UUID

    var body: some HTML {
        section(.class("account-group")) {
            h2(.class("account-group-heading")) {
                span { title }
                span(.class("account-group-count")) { "\(accounts.count)" }
            }
            for account in accounts {
                AccountBlock(account: account, state: AccountRowState(account: account, currentUserID: currentUserID))
            }
        }
    }
}

/// One account, and what can be done to it.
private struct AccountBlock: HTML {
    let account: AccountSummary
    let state: AccountRowState

    var body: some HTML {
        div(.class("account-block")) {
            div(.class("tool-row-main account-identity")) {
                div(.class("account-name")) { account.username }
            }
            div(.class("account-block-action")) {
                switch state {
                case .current:
                    span(.class("account-self")) { "Your account" }
                case .disabled:
                    AccountAccessAction(account: account, action: .enable, label: "Enable account")
                case .active(let role):
                    AccountAccessMenu(account: account, role: role)
                }
            }
        }
    }
}

private enum AccountRowState {
    case current
    case active(AccountRole)
    case disabled

    init(account: AccountSummary, currentUserID: UUID) {
        switch (account.id == currentUserID, account.status) {
        case (true, _): self = .current
        case (false, .disabled): self = .disabled
        case (false, .pending), (false, .approved): self = .active(account.role)
        }
    }
}

private struct AccountAccessMenu: HTML {
    let account: AccountSummary
    let role: AccountRole

    var body: some HTML {
        details(.class("account-menu account-access")) {
            summary(
                .class("account-summary"),
                .init(name: "aria-label", value: "Edit access for \(account.username)")
            ) {
                span { "Edit access" }
                span(
                    .class("account-chevron"),
                    .init(name: "aria-hidden", value: "true")
                ) { "▾" }
            }
            div(.class("account-dropdown account-access-dropdown")) {
                switch role {
                case .user:
                    AccountAccessAction(
                        account: account, action: .member,
                        label: "Make member", presentation: .menuItem
                    )
                    AccountAccessAction(
                        account: account, action: .administrator,
                        label: "Make administrator", presentation: .menuItem
                    )
                case .member:
                    AccountAccessAction(
                        account: account, action: .user,
                        label: "Make user", presentation: .menuItem
                    )
                    AccountAccessAction(
                        account: account, action: .administrator,
                        label: "Make administrator", presentation: .menuItem
                    )
                case .administrator:
                    AccountAccessAction(
                        account: account, action: .user,
                        label: "Make user", presentation: .menuItem
                    )
                    AccountAccessAction(
                        account: account, action: .member,
                        label: "Make member", presentation: .menuItem
                    )
                }
                AccountAccessAction(
                    account: account, action: .disable,
                    label: "Disable account", presentation: .menuItem
                )
            }
        }
    }
}

private struct AccountAccessAction: HTML {
    enum Presentation: Sendable {
        case inline
        case menuItem
    }

    let account: AccountSummary
    let action: AccountAction
    let label: String
    var presentation: Presentation = .inline

    private var buttonClass: String {
        switch (presentation, action) {
        case (.menuItem, .disable):
            return "account-menu-item account-menu-item-danger"
        case (.menuItem, _):
            return "account-menu-item"
        case (.inline, .disable):
            return "account-access-button is-danger"
        case (.inline, _):
            return "account-access-button"
        }
    }

    var body: some HTML {
        form(.method(.post), .action("/accounts/action"), .class("account-access-form")) {
            input(.type(.hidden), .name("id"), .value(account.id.uuidString))
            input(.type(.hidden), .name("action"), .value(action.rawValue))
            button(
                .type(.submit),
                .class(buttonClass),
                .init(name: "aria-label", value: "\(label): \(account.username)")
            ) { label }
        }
    }
}
