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
}

private struct AppHeaderLinks: HTML, Sendable {
    enum Scope: Sendable {
        case dashboard
        case administration
    }

    let section: TurgaiAppSection
    let scope: Scope

    private var accountsLink: some HTML {
        switch section {
        case .accounts:
            AppNavigationLink(
                href: "/accounts",
                label: "Accounts",
                icon: .accounts,
                isActive: true
            )
        case .bots, .tools, .channels:
            AppNavigationLink(href: "/accounts", label: "Accounts", icon: .accounts)
        }
    }

    private var channelsLink: some HTML {
        switch section {
        case .channels:
            AppNavigationLink(
                href: "/channels",
                label: "Channels",
                icon: .channels,
                isActive: true
            )
        case .bots, .tools, .accounts:
            AppNavigationLink(href: "/channels", label: "Channels", icon: .channels)
        }
    }

    var body: some HTML {
        div(.class("app-nav-links")) {
            switch section {
            case .bots:
                AppNavigationLink(href: "/", label: "Bots", icon: .bots, isActive: true)
                AppNavigationLink(href: "/tools", label: "Tools", icon: .tools)
            case .tools:
                AppNavigationLink(href: "/", label: "Bots", icon: .bots)
                AppNavigationLink(href: "/tools", label: "Tools", icon: .tools, isActive: true)
            case .channels, .accounts:
                AppNavigationLink(href: "/", label: "Bots", icon: .bots)
                AppNavigationLink(href: "/tools", label: "Tools", icon: .tools)
            }
            if case .administration = scope {
                channelsLink
                accountsLink
            }
        }
    }
}

private struct AppNavigationLink: HTML, Sendable {
    let href: String
    let label: String
    let icon: AppNavigationIcon
    let isActive: Bool

    init(
        href: String,
        label: String,
        icon: AppNavigationIcon,
        isActive: Bool = false
    ) {
        self.href = href
        self.label = label
        self.icon = icon
        self.isActive = isActive
    }

    var body: some HTML {
        a(
            .href(href),
            .class(isActive ? "nav-link nav-link-active" : "nav-link"),
            .init(name: "aria-label", value: label),
            .init(name: "aria-current", value: isActive ? "page" : nil)
        ) {
            AppNavigationIconView(icon: icon)
            span(.class("nav-link-label")) { label }
        }
    }
}

private enum AppNavigationIcon: Sendable {
    case bots
    case tools
    case channels
    case accounts

    var path: String {
        switch self {
        case .bots:
            "M12 8V4M8 4h8M16 4v4M4 12h16v8a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-8ZM2 12h2M20 12h2M8 16h.01M16 16h.01"
        case .tools:
            "m14.7 6.3 3 3M4 20l5.3-5.3m2.7-2.7 6.4-6.4a2.1 2.1 0 0 0-3-3L9 8l3 3-8 8a2.1 2.1 0 0 0 3 3l5.7-5.7"
        case .channels:
            "M12 20v-4M8.5 16a5 5 0 0 1 7 0M5 13a10 10 0 0 1 14 0M2 10a15 15 0 0 1 20 0M12 4V2"
        case .accounts:
            "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8ZM22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"
        }
    }
}

private struct AppNavigationIconView: HTML, Sendable {
    let icon: AppNavigationIcon

    var body: some HTML {
        SVG.svg(
            .viewBox(0, 0, 24, 24),
            .fill(.none),
            .stroke("currentColor"),
            .strokeWidth(2),
            .strokeLinecap(.round),
            .strokeLinejoin(.round),
            .class("nav-icon"),
            .init(name: "aria-hidden", value: "true")
        ) {
            switch icon {
            case .bots:
                SVG.path(.d("M12 8V4H8"))
                SVG.rect(.width(16), .height(12), .x(4), .y(8), .rx(2))
                SVG.path(.d("M2 14h2"))
                SVG.path(.d("M20 14h2"))
                SVG.path(.d("M15 13v2"))
                SVG.path(.d("M9 13v2"))
            case .tools:
                SVG.path(.d("M3 2v1c0 1 2 1 2 2S3 6 3 7s2 1 2 2-2 1-2 2 2 1 2 2"))
                SVG.path(.d("M18 6h.01"))
                SVG.path(.d("M6 18h.01"))
                SVG.path(.d("M20.83 8.83a4 4 0 0 0-5.66-5.66l-12 12a4 4 0 1 0 5.66 5.66Z"))
                SVG.path(.d("M18 11.66V22a4 4 0 0 0 4-4V6"))
            case .channels:
                SVG.path(.d("M12 12h.01"))
                SVG.path(.d("M16 12h.01"))
                SVG.path(.d("m17 7 5 5-5 5"))
                SVG.path(.d("m7 7-5 5 5 5"))
                SVG.path(.d("M8 12h.01"))
            case .accounts:
                SVG.path(.d(icon.path))
            }
        }
    }
}
