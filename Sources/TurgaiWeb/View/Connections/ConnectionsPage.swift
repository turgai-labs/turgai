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

/// A space's connections, its ways in from elsewhere: each to change or remove, and adding one.
struct ConnectionsPage: HTMLDocument, Sendable {
    let user: AuthenticatedUser
    let space: SpaceListing
    let connections: [ConnectionListItem]

    private var path: String { "/spaces/\(space.id.rawValue.uuidString)/connections" }

    var title: String { "Turgai — \(space.name) connections" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("app-page channels-page")) {
            PageShell(
                kind: .private,
                header: PageHeader(user: user, navigation: .active(.spaces)),
                footer: PageFooter { EmptyFooterContent() }
            ) {
                SpaceTabs(space: space, active: .connections)
                section(.class("page-intro detail-page-intro")) {
                    div {
                        h1 { "Connections" }
                        p(.class("lede")) {
                            "The places people reach this space from: their chats are its conversations."
                        }
                    }
                    a(.href(path + "/new"), .class("button button-accent")) { "+ Add connection" }
                }
                if connections.isEmpty {
                    NoConnections(path: path)
                } else {
                    section(.class("channels-list"), .init(name: "aria-label", value: "Connections")) {
                        for connection in connections { ConnectionRow(path: path, connection: connection) }
                    }
                }
            }
        }
    }
}

/// What a space's connections page shows before it has any.
struct NoConnections: HTML, Sendable {
    /// Where the space's connections are.
    let path: String

    var body: some HTML {
        div(.class("empty-state")) {
            p(.class("eyebrow")) { "No connections yet" }
            h2 { "Give this space a way in from elsewhere." }
            a(.href(path + "/new"), .class("button button-accent")) { "+ Add connection" }
        }
    }
}

/// One connection in the list: how it's doing, and editing or deleting it.
struct ConnectionRow: HTML, Sendable {
    /// Where the space's connections are.
    let path: String
    let connection: ConnectionListItem

    var body: some HTML {
        div(.class("channel-row")) {
            ConnectionRowSummary(connection: connection)
            ConnectionRowActions(path: path + "/\(connection.id)")
        }
    }
}

/// A connection's name, whether it's running, and what it's set up with.
struct ConnectionRowSummary: HTML, Sendable {
    let connection: ConnectionListItem

    /// Whether it's running, in a word.
    private var status: String { connection.enabled ? "Active" : "Paused" }
    /// Whether its bot's token is set.
    private var token: String { connection.hasToken ? "Token set" : "No token" }

    var body: some HTML {
        div(.class("channel-row-main")) {
            div(.class("channel-row-heading")) {
                div(.class("channel-name")) { connection.label }
                span(.class("detail-status")) { status }
            }
            div(.class("channel-meta")) {
                span { "Telegram" }
                span { token }
                if let stopped = connection.stopped { span { "Stopped: \(stopped)" } }
            }
        }
    }
}

/// Editing a connection, or deleting it.
struct ConnectionRowActions: HTML, Sendable {
    /// Where it's changed and deleted.
    let path: String

    var body: some HTML {
        div(.class("channel-row-actions")) {
            a(.href(path), .class("button button-secondary")) { "Edit" }
            form(.method(.post), .action(path + "/delete"), .class("channel-delete-form")) {
                button(.type(.submit), .class("text-button text-button-danger")) { "Delete" }
            }
        }
    }
}
