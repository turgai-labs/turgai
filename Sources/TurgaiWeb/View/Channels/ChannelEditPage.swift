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
    let channel: ChannelEditItem
    let bots: [ChannelBotOption]
    let error: String?

    init(user: AuthenticatedUser, channel: ChannelEditItem, bots: [ChannelBotOption] = [], error: String? = nil) {
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
                        TurgaiBreadcrumb(
                            parentTitle: "Channels",
                            parentHref: "/channels",
                            currentTitle: "Edit channel"
                        )
                        h1 { channel.label }
                        p(.class("lede")) { "Telegram" }
                    }
                }
                if let error { p(.class("error page-error")) { error } }
                div(.class("detail-layout")) {
                    section(.class("detail-main")) {
                        h2 { "Channel settings" }
                        form(.method(.post), .action("/channels/update")) {
                            input(.type(.hidden), .name("id"), .value(channel.id.uuidString))
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Label" }
                                input(.type(.text), .name("label"), .value(channel.label), .required)
                            }
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Bot" }
                                select(.name("agentProfileID")) {
                                    TurgaiSelectOption(
                                        value: "",
                                        label: "Default routing",
                                        selection: channel.agentProfileID == nil ? .selected : .unselected
                                    )
                                    for bot in bots {
                                        TurgaiSelectOption(
                                            value: bot.id,
                                            label: bot.name,
                                            selection: bot.id == channel.agentProfileID ? .selected : .unselected
                                        )
                                    }
                                }
                                p(.class("hint")) {
                                    "The agent answering chats on this channel."
                                }
                            }
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Channel status" }
                                span(.class("field-inline")) {
                                    input(
                                        .type(.checkbox),
                                        .name("enabled"),
                                        .value("on")
                                    )
                                    .attributes(.checked, when: channel.enabled)
                                    span { "Active" }
                                }
                                p(.class("hint")) {
                                    "When active, Turgai starts receiving Telegram updates for this channel."
                                }
                            }
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Who can reach it" }
                                input(
                                    .type(.text),
                                    .name("chatIDs"),
                                    .value(channel.chatIDs.map(String.init).joined(separator: ",")),
                                    .placeholder("Optional, comma-separated")
                                )
                                p(.class("hint")) {
                                    "Leave empty to let Turgai listen to every chat."
                                }
                            }
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Bot token" }
                                input(
                                    .type(.password),
                                    .name("token"),
                                    .autocomplete("off"),
                                    .placeholder("Leave empty to keep the current token")
                                )
                                p(.class("hint")) {
                                    channel.hasToken
                                        ? "A token is currently set. Enter a new one to replace it."
                                        : "No token is currently set."
                                }
                            }
                            button(.type(.submit), .class("button button-accent")) { "Save changes" }
                        }
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
