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

/// One of a space's connections: changing it, or removing it.
struct ConnectionEditPage: HTMLDocument, Sendable {
    let user: AuthenticatedUser
    let space: SpaceListing
    let connection: ConnectionDraft
    let error: String?

    init(user: AuthenticatedUser, space: SpaceListing, connection: ConnectionDraft, error: String? = nil) {
        self.user = user
        self.space = space
        self.connection = connection
        self.error = error
    }

    /// Where it's changed and removed: under its space.
    private var path: String { "/spaces/\(space.id.rawValue.uuidString)/connections/\(connection.id)" }

    var title: String { "Turgai — \(connection.label)" }
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
                        h1 { connection.label }
                        p(.class("lede")) { "Telegram" }
                    }
                }
                if let error { p(.class("error page-error")) { error } }
                div(.class("detail-layout")) {
                    section(.class("detail-main")) {
                        h2 { "Connection settings" }
                        ConnectionSettingsForm(connection: connection, action: path + "/update")
                        form(.method(.post), .action(path + "/delete"), .class("delete-form")) {
                            button(.type(.submit), .class("text-button text-button-danger")) { "Remove connection" }
                        }
                    }
                }
            }
        }
    }
}

/// A connection's settings: its label, whether it's on, who reaches it, its token.
struct ConnectionSettingsForm: HTML, Sendable {
    let connection: ConnectionDraft
    let action: String

    var body: some HTML {
        form(.method(.post), .action(action)) {
            label(.class("form-field")) {
                span(.class("field-label")) { "Label" }
                input(.type(.text), .name("label"), .value(connection.label), .required)
            }
            ConnectionStatusField(enabled: connection.enabled)
            label(.class("form-field")) {
                span(.class("field-label")) { "Who can reach it" }
                input(
                    .type(.text), .name("chatIDs"), .value(connection.chatIDs),
                    .placeholder("Optional, comma-separated"))
                p(.class("hint")) { "Leave empty to let Turgai listen to every chat." }
            }
            ConnectionTokenField(hasToken: connection.hasToken)
            button(.type(.submit), .class("button button-accent")) { "Save changes" }
        }
    }
}

/// Whether the connection takes Telegram's updates.
struct ConnectionStatusField: HTML, Sendable {
    let enabled: Bool

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Status" }
            span(.class("field-inline")) {
                input(.type(.checkbox), .name("enabled"), .value("on")).attributes(.checked, when: enabled)
                span { "Active" }
            }
            p(.class("hint")) { "When active, Turgai starts receiving Telegram updates for this connection." }
        }
    }
}

/// A new bot token, and whether one is saved.
struct ConnectionTokenField: HTML, Sendable {
    let hasToken: Bool

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Bot token" }
            input(
                .type(.password), .name("token"), .autocomplete("off"),
                .placeholder("Leave empty to keep the current token"))
            p(.class("hint")) {
                hasToken ? "A token is currently set. Enter a new one to replace it." : "No token is currently set."
            }
        }
    }
}
