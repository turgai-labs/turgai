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

struct AppHeader: HTML, Sendable {
    let user: AuthenticatedUser
    let section: TurgaiAppSection

    init(user: AuthenticatedUser, section: TurgaiAppSection) {
        self.user = user
        self.section = section
    }

    var body: some HTML {
        header(.class("app-header")) {
            a(.href("/"), .class("wordmark")) {
                img(.src("/skylark.svg"), .alt(""), .class("wordmark-logo"))
                span(.class("wordmark-text")) { "turgai" }
            }
            nav(.class("app-nav")) {
                div(.class("app-nav-links")) {
                    if section == .bots {
                        a(
                            .href("/"), .class("nav-link nav-link-active"),
                            .init(name: "aria-current", value: "page")
                        ) { "Bots" }
                    } else {
                        a(.href("/"), .class("nav-link")) { "Bots" }
                    }
                    if section == .tools {
                        a(
                            .href("/tools"), .class("nav-link nav-link-active"),
                            .init(name: "aria-current", value: "page")
                        ) { "Tools" }
                    } else {
                        a(.href("/tools"), .class("nav-link")) { "Tools" }
                    }
                    if case .administrator = user, section == .accounts {
                        a(
                            .href("/accounts"), .class("nav-link nav-link-active"),
                            .init(name: "aria-current", value: "page")
                        ) { "Accounts" }
                    } else if case .administrator = user {
                        a(.href("/accounts"), .class("nav-link")) { "Accounts" }
                    }
                }
                label(.class("theme-switch")) {
                    input(
                        .type(.checkbox),
                        .class("theme-switch-input"),
                        .init(name: "data-theme-toggle", value: ""),
                        .init(name: "role", value: "switch"),
                        .init(name: "aria-label", value: "Switch to dark theme"),
                        .init(name: "aria-checked", value: "false")
                    )
                    span(
                        .class("theme-switch-track"),
                        .init(name: "aria-hidden", value: "true")
                    ) {
                        span(.class("theme-switch-icon")) { "☀" }
                        span(.class("theme-switch-thumb")) {}
                        span(.class("theme-switch-icon")) { "☾" }
                    }
                }
                details(.class("account-menu")) {
                    summary(
                        .class("account-summary"),
                        .init(name: "aria-label", value: "Account menu")
                    ) {
                        span(.class("account-name")) { user.username }
                        span(.class("account-chevron")) { "▾" }
                    }
                    div(.class("account-dropdown")) {
                        form(.method(.post), .action("/logout"), .class("account-logout-form")) {
                            button(
                                .type(.submit),
                                .class("account-menu-item account-menu-item-danger")
                            ) {
                                "Sign out"
                            }
                        }
                    }
                }
            }
        }
    }
}
