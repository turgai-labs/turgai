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

enum PageHeaderNavigation: Sendable {
    case none
    case active(TurgaiAppSection)
}

struct PageHeader: HTML, Sendable {
    let user: AuthenticatedUser?
    let navigation: PageHeaderNavigation

    init(
        user: AuthenticatedUser? = nil,
        navigation: PageHeaderNavigation = .none
    ) {
        self.user = user
        self.navigation = navigation
    }

    var body: some HTML {
        header(.class("page-header app-header")) {
            a(.href("/"), .class("wordmark")) {
                img(.src("/skylark.svg"), .alt(""), .class("wordmark-logo"))
                span(.class("wordmark-text")) { "turgai" }
            }
            if let user {
                nav(.class("app-nav")) {
                    if case .member = user, case .active(let section) = navigation {
                        AppHeaderLinks(section: section, scope: .dashboard)
                    }
                    if case .administrator = user, case .active(let section) = navigation {
                        AppHeaderLinks(section: section, scope: .administration)
                    }
                    ThemeSwitch()
                    AccountMenu(username: user.username)
                }
            }
        }
    }
}

/// Switches between the light and the dark theme.
private struct ThemeSwitch: HTML, Sendable {
    var body: some HTML {
        label(.class("theme-switch")) {
            input(
                .type(.checkbox),
                .class("theme-switch-input"),
                .init(name: "data-theme-toggle", value: ""),
                .init(name: "role", value: "switch"),
                .init(name: "aria-label", value: "Switch to dark theme"),
                .init(name: "aria-checked", value: "false")
            )
            span(.class("theme-switch-track"), .init(name: "aria-hidden", value: "true")) {
                span(.class("theme-switch-icon")) { "☀" }
                span(.class("theme-switch-thumb")) {}
                span(.class("theme-switch-icon")) { "☾" }
            }
        }
    }
}

/// The signed-in account's name, and signing out.
private struct AccountMenu: HTML, Sendable {
    let username: String

    var body: some HTML {
        details(.class("account-menu")) {
            summary(.class("account-summary"), .init(name: "aria-label", value: "Account menu")) {
                span(.class("account-name")) { username }
                span(.class("account-chevron")) { "▾" }
            }
            div(.class("account-dropdown")) {
                form(.method(.post), .action("/logout"), .class("account-logout-form")) {
                    button(.type(.submit), .class("account-menu-item account-menu-item-danger")) { "Sign out" }
                }
            }
        }
    }
}

private struct AppHeaderLinks: HTML, Sendable {
    enum Scope: Sendable {
        case dashboard
        case administration
    }

    let section: TurgaiAppSection
    let scope: Scope

    var body: some HTML {
        div(.class("app-nav-links")) {
            AppNavigationLink(href: "/", label: "Bots", isActive: section == .bots)
            AppNavigationLink(href: "/tools", label: "Tools", isActive: section == .tools)
            if case .administration = scope {
                AppNavigationLink(href: "/channels", label: "Channels", isActive: section == .channels)
                AppNavigationLink(href: "/accounts", label: "Accounts", isActive: section == .accounts)
            }
        }
    }
}

private struct AppNavigationLink: HTML, Sendable {
    let href: String
    let label: String
    let isActive: Bool

    var body: some HTML {
        a(
            .href(href),
            .class(isActive ? "nav-link nav-link-active" : "nav-link"),
            .init(name: "aria-current", value: isActive ? "page" : nil)
        ) {
            label
        }
    }
}
