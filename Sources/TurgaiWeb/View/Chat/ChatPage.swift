import Elementary
import ElementaryHTMX4
import ElementaryHTMX4WS
import TurgaiApplication

struct ChatPage: HTMLDocument, Sendable {
    enum Presentation: Sendable {
        case publicChat
        case dashboard
    }

    let user: AuthenticatedUser?
    let profile: TurgaiAgentProfile
    /// The conversation it shows, as the API calls it.
    let conversationID: String
    let presentation: Presentation

    init(user: AuthenticatedUser, profile: TurgaiAgentProfile, conversationID: String, presentation: Presentation) {
        self.user = user
        self.profile = profile
        self.conversationID = conversationID
        self.presentation = presentation
    }

    var title: String { "Turgai — Chat with \(profile.name)" }
    var head: some HTML { TurgaiHead() }

    private var shellKind: PageShellKind {
        switch presentation {
        case .publicChat: .public
        case .dashboard: .private
        }
    }

    private var headerNavigation: PageHeaderNavigation {
        switch presentation {
        case .publicChat: .none
        case .dashboard: .active(.bots)
        }
    }

    var body: some HTML {
        main(
            .class("app-page chat-app-page overlay-scroll-page"),
            .hx.ws.connect("/api/v1/chat?conversationID=\(conversationID)"),
            // The socket sends only swaps that say where they go.
            .hx.swap(.none)
        ) {
            PageShell(
                kind: shellKind,
                contentLayout: .overlayScroll,
                header: PageHeader(user: user, navigation: headerNavigation),
                footer: PageFooter(behavior: .sticky) { ChatFooterContent(profileName: profile.name) }
            ) {
                div(.class("chat-page")) {
                    if case .dashboard = presentation {
                        div(.class("chat-header")) {
                            div(.class("chat-header-main")) {
                                a(.href("/agents/\(profile.id)"), .class("chat-back")) {
                                    "← \(profile.name)"
                                }
                                h1 { "Chat" }
                            }
                            span(.class("chat-model")) {
                                TurgaiModelPresentation.displayName(for: profile.model)
                            }
                        }
                    }
                    section(
                        .class("chat-messages chat-wrapper"),
                        .id("chat-messages"),
                        .init(name: "aria-label", value: "Conversation with \(profile.name)")
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
