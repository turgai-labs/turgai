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

struct NewChannelPage: HTMLDocument, Sendable {
    let user: AuthenticatedUser
    let error: String?

    init(user: AuthenticatedUser, error: String? = nil) {
        self.user = user
        self.error = error
    }

    var title: String { "Turgai — New channel" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("app-page")) {
            PageShell(
                kind: .private,
                header: PageHeader(user: user, navigation: .active(.channels)),
                footer: PageFooter { EmptyFooterContent() }
            ) {
                section(.class("page-intro detail-page-intro")) {
                    div {
                        TurgaiBreadcrumb(
                            parentTitle: "Channels",
                            parentHref: "/channels",
                            currentTitle: "New channel"
                        )
                        h1 { "Add channel" }
                        p(.class("lede")) { "Choose where Turgai should listen." }
                    }
                }
                if let error { p(.class("error page-error")) { error } }
                div(.class("detail-layout")) {
                    section(.class("detail-main")) {
                        NewChannelForm()
                    }
                }
            }
        }
    }
}

/// A new channel: its kind, Telegram for now, and a label.
struct NewChannelForm: HTML, Sendable {
    var body: some HTML {
        form(.method(.post), .action("/channels/create")) {
            label(.class("form-field")) {
                span(.class("field-label")) { "Type" }
                span(.class("field-inline")) {
                    input(.type(.radio), .name("kind"), .value("telegram")).attributes(.checked, when: true)
                    span { "Telegram" }
                }
            }
            label(.class("form-field")) {
                span(.class("field-label")) { "Label" }
                input(.type(.text), .name("label"), .required)
                p(.class("hint")) { "A name you will recognize, like “Team Telegram”." }
            }
            button(.type(.submit), .class("button button-accent")) { "Create channel" }
        }
    }
}
