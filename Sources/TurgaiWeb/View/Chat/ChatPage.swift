import Elementary
import ElementaryHTMX4
import ElementaryHTMX4WS
import TurgaiApplication
import TurgaiDomain

/// A conversation in a space, with the bot answering it.
struct ChatPage: HTMLDocument, Sendable {
    let user: AuthenticatedUser?
    let bot: Bot
    /// The space whose conversation it is.
    let space: String
    /// The conversation it shows, as the API calls it.
    let conversationID: String

    init(user: AuthenticatedUser, bot: Bot, space: String, conversationID: String) {
        self.user = user
        self.bot = bot
        self.space = space
        self.conversationID = conversationID
    }

    var title: String { "Turgai — Chat with \(bot.name)" }
    var head: some HTML { TurgaiHead() }


    var body: some HTML {
        main(
            .class("app-page chat-app-page overlay-scroll-page"),
            .hx.ws.connect("/api/v1/chat?space=\(space)&conversationID=\(conversationID)"),
            // The socket sends only swaps that say where they go.
            .hx.swap(.none)
        ) {
            PageShell(
                kind: .private,
                contentLayout: .overlayScroll,
                header: PageHeader(user: user, navigation: .active(.spaces)),
                footer: PageFooter(behavior: .sticky) { ChatFooterContent(profileName: bot.name.rawValue) }
            ) {
                div(.class("chat-page")) {
                    div(.class("chat-header")) {
                        div(.class("chat-header-main")) {
                            a(.href("/spaces/\(space)/bots/\(bot.id)"), .class("chat-back")) {
                                "← \(bot.name)"
                            }
                            h1 { "Chat" }
                        }
                        span(.class("chat-model")) {
                            bot.modelIdentifier
                        }
                    }
                    section(
                        .class("chat-messages chat-wrapper"),
                        .id("chat-messages"),
                        .init(name: "aria-label", value: "Conversation with \(bot.name)")
                    ) {
                        div(.class("chat-messages-content"), .id("chat-messages-content")) {
                            div(.class("chat-empty chat-loading"), .id("chat-empty")) {
                                p { "Restoring your conversation…" }
                            }
                        }
                        div(
                            .class("chat-activity"),
                            .id("conversation-activity"),
                            .init(name: "aria-live", value: "polite")
                        ) {}
                    }
                }
            }
        }
    }
}
