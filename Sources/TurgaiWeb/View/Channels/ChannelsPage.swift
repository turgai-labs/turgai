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

struct ChannelsPage: HTMLDocument, Sendable {
    let user: AuthenticatedUser
    let channels: [ChannelListItem]
    let error: String?

    init(user: AuthenticatedUser, channels: [ChannelListItem], error: String? = nil) {
        self.user = user
        self.channels = channels
        self.error = error
    }

    var title: String { "Turgai — Channels" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("app-page channels-page")) {
            PageShell(
                kind: .private,
                header: PageHeader(user: user, navigation: .active(.channels)),
                footer: PageFooter { EmptyFooterContent() }
            ) {
                section(.class("page-intro detail-page-intro")) {
                    div {
                        h1 { "Channels" }
                        p(.class("lede")) { "Connect Turgai to the places where people can reach it." }
                    }
                    a(.href("/channels/new"), .class("button button-accent")) { "+ Add channel" }
                }
                if let error { p(.class("error page-error")) { error } }
                if channels.isEmpty {
                    NoChannels()
                } else {
                    section(.class("channels-list"), .init(name: "aria-label", value: "Channels")) {
                        for channel in channels { ChannelRow(channel: channel) }
                    }
                }
            }
        }
    }
}

/// What the channels page shows before there are any.
struct NoChannels: HTML, Sendable {
    var body: some HTML {
        div(.class("empty-state")) {
            p(.class("eyebrow")) { "No channels yet" }
            h2 { "Give Turgai a way to reach the world." }
            a(.href("/channels/new"), .class("button button-accent")) { "+ Add channel" }
        }
    }
}

/// One channel in the list: how it's doing, and editing or deleting it.
struct ChannelRow: HTML, Sendable {
    let channel: ChannelListItem

    /// Whether it's running, in a word.
    private var status: String { channel.enabled ? "Active" : "Paused" }
    /// Whether its bot's token is set.
    private var token: String { channel.hasToken ? "Token set" : "No token" }

    var body: some HTML {
        div(.class("channel-row")) {
            div(.class("channel-row-main")) {
                div(.class("channel-row-heading")) {
                    div(.class("channel-name")) { channel.label }
                    span(.class("detail-status")) { status }
                }
                div(.class("channel-meta")) {
                    span { "Telegram" }
                    span { token }
                    if let botName = channel.botName { span { "Bot: \(botName)" } }
                }
            }
            div(.class("channel-row-actions")) {
                a(.href("/channels/\(channel.id.uuidString)"), .class("button button-secondary")) { "Edit" }
                form(.method(.post), .action("/channels/delete"), .class("channel-delete-form")) {
                    input(.type(.hidden), .name("id"), .value(channel.id.uuidString))
                    button(.type(.submit), .class("text-button text-button-danger")) { "Delete" }
                }
            }
        }
    }
}
