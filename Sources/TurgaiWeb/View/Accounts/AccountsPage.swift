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
            div(.class("app-shell")) {
                AppHeader(user: user, section: .accounts)
                section(.class("page-intro detail-page-intro")) {
                    div {
                        TurgaiBreadcrumb(parentTitle: "Bots", parentHref: "/", currentTitle: "Accounts")
                        h1 { "Accounts" }
                        p(.class("lede")) { "Decide who can use this Turgai and what they can change." }
                    }
                }
                if let error { p(.class("error page-error")) { error } }
                section(.class("accounts-list")) {
                    for account in accounts {
                        div(.class("account-row")) {
                            div(.class("account-row-identity")) {
                                strong { account.username }
                                span(.class("account-role")) { account.role.rawValue }
                            }
                            span(.class("account-status account-status-(account.status.rawValue)")) {
                                account.status.rawValue
                            }
                            div(.class("account-row-actions")) {
                                if account.status == .pending {
                                    form(.method(.post), .action("/accounts/action")) {
                                        input(.type(.hidden), .name("id"), .value(account.id.uuidString))
                                        input(.type(.hidden), .name("action"), .value("approve"))
                                        button(.type(.submit), .class("text-button")) { "Approve" }
                                    }
                                } else if account.id != user.id {
                                    form(.method(.post), .action("/accounts/action")) {
                                        input(.type(.hidden), .name("id"), .value(account.id.uuidString))
                                        input(.type(.hidden), .name("action"), .value("disable"))
                                        button(.type(.submit), .class("text-button text-button-danger")) { "Disable" }
                                    }
                                }
                                if account.status != .disabled, account.id != user.id {
                                    form(.method(.post), .action("/accounts/action")) {
                                        input(.type(.hidden), .name("id"), .value(account.id.uuidString))
                                        input(
                                            .type(.hidden), .name("action"),
                                            .value(account.role == .administrator ? "member" : "administrator")
                                        )
                                        button(.type(.submit), .class("text-button")) {
                                            account.role == .administrator ? "Make member" : "Make administrator"
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
