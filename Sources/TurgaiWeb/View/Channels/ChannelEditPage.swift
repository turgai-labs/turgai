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

struct ChannelEditPage: HTMLDocument, Sendable {
    let user: AuthenticatedUser
    let channel: ChannelDraft
    let bots: [ChannelBotOption]
    let error: String?

    init(user: AuthenticatedUser, channel: ChannelDraft, bots: [ChannelBotOption] = [], error: String? = nil) {
        self.user = user
        self.channel = channel
        self.bots = bots
        self.error = error
    }

    var title: String { "Turgai — \(channel.label)" }
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
                        TurgaiBreadcrumb(parentTitle: "Channels", parentHref: "/channels", currentTitle: "Edit channel")
                        h1 { channel.label }
                        p(.class("lede")) { "Telegram" }
                    }
                }
                if let error { p(.class("error page-error")) { error } }
                div(.class("detail-layout")) {
                    section(.class("detail-main")) {
                        h2 { "Channel settings" }
                        ChannelSettingsForm(channel: channel, bots: bots)
                        form(.method(.post), .action("/channels/delete"), .class("delete-form")) {
                            input(.type(.hidden), .name("id"), .value(channel.id.uuidString))
                            button(.type(.submit), .class("text-button text-button-danger")) { "Delete channel" }
                        }
                    }
                }
            }
        }
    }
}

/// A channel's settings: its label, which bot answers, whether it's on, who reaches it, its token.
struct ChannelSettingsForm: HTML, Sendable {
    let channel: ChannelDraft
    let bots: [ChannelBotOption]

    var body: some HTML {
        form(.method(.post), .action("/channels/update")) {
            input(.type(.hidden), .name("id"), .value(channel.id.uuidString))
            label(.class("form-field")) {
                span(.class("field-label")) { "Label" }
                input(.type(.text), .name("label"), .value(channel.label), .required)
            }
            ChannelRoutingField(routing: channel.routing, bots: bots)
            ChannelStatusField(enabled: channel.enabled)
            label(.class("form-field")) {
                span(.class("field-label")) { "Who can reach it" }
                input(
                    .type(.text), .name("chatIDs"), .value(channel.chatIDs),
                    .placeholder("Optional, comma-separated"))
                p(.class("hint")) { "Leave empty to let Turgai listen to every chat." }
            }
            ChannelTokenField(hasToken: channel.hasToken)
            button(.type(.submit), .class("button button-accent")) { "Save changes" }
        }
    }
}

/// Which bot answers the channel's chats: the default one, or one chosen.
struct ChannelRoutingField: HTML, Sendable {
    let routing: ChannelAgentRouting
    let bots: [ChannelBotOption]

    private var options: [(String, String)] {
        [("", "Default routing")] + bots.map { (bot: ChannelBotOption) -> (String, String) in (bot.id, bot.name) }
    }

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Bot" }
            select(.name("agentProfileID")) {
                TurgaiSelectOptions(options: options, value: routing.profileID ?? "")
            }
            p(.class("hint")) { "The agent answering chats on this channel." }
        }
    }
}

/// Whether the channel takes Telegram's updates.
struct ChannelStatusField: HTML, Sendable {
    let enabled: Bool

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Channel status" }
            span(.class("field-inline")) {
                input(.type(.checkbox), .name("enabled"), .value("on")).attributes(.checked, when: enabled)
                span { "Active" }
            }
            p(.class("hint")) { "When active, Turgai starts receiving Telegram updates for this channel." }
        }
    }
}

/// A new bot token, and whether one is saved.
struct ChannelTokenField: HTML, Sendable {
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
