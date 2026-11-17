import AnyLanguageModel
import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import NIOCore
import TurgaiApplication
import TurgaiDomain
import TurgaiHail
import TurgaiPersistence
import TurgaiSpaces
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A new connection of a space.
struct NewConnectionPage: HTMLDocument, Sendable {
    let user: AuthenticatedUser
    /// The space it's a way into.
    let space: SpaceListing
    let error: String?

    init(user: AuthenticatedUser, space: SpaceListing, error: String? = nil) {
        self.user = user
        self.space = space
        self.error = error
    }

    var title: String { "Turgai — New connection" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("app-page")) {
            PageShell(
                kind: .private,
                header: PageHeader(user: user, navigation: .active(.spaces)),
                footer: PageFooter { EmptyFooterContent() }
            ) {
                SpaceTabs(space: space, active: .connections)
                section(.class("page-intro detail-page-intro")) {
                    div {
                        h1 { "Add connection" }
                        p(.class("lede")) { "Its chats become conversations in this space, answered by its main bot." }
                    }
                }
                if let error { p(.class("error page-error")) { error } }
                div(.class("detail-layout")) {
                    section(.class("detail-main")) {
                        NewConnectionForm(action: "/spaces/\(space.id.rawValue.uuidString)/connections/create")
                    }
                }
            }
        }
    }
}

/// A new connection: its kind, Telegram for now, and a label.
struct NewConnectionForm: HTML, Sendable {
    let action: String

    var body: some HTML {
        form(.method(.post), .action(action)) {
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
            button(.type(.submit), .class("button button-accent")) { "Create connection" }
        }
    }
}
