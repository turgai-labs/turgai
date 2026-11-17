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

#if canImport(FoundationEssentials)
    import FoundationEssentials
    import FoundationInternationalization
#else
    import Foundation
#endif

struct AgentDetailPage: HTMLDocument, Sendable {
    enum Placement: Sendable {
        /// The space's main bot: who answers when no other is asked for.
        case main
        case additional
    }

    let user: AuthenticatedUser
    /// The space whose bot it is, as the person sees it.
    let space: SpaceListing
    let bot: Bot
    /// The form's values: the saved bot, or what was submitted when saving failed.
    let draft: AgentDraft
    let runtime: [TurgaiAgentRuntimeSnapshot]
    let placement: Placement
    let error: String?

    init(
        user: AuthenticatedUser,
        space: SpaceListing,
        bot: Bot,
        draft: AgentDraft,
        runtime: [TurgaiAgentRuntimeSnapshot] = [],
        placement: Placement,
        error: String? = nil
    ) {
        self.user = user
        self.space = space
        self.bot = bot
        self.draft = draft
        self.runtime = runtime
        self.placement = placement
        self.error = error
    }

    var title: String { "Turgai — \(bot.name)" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("app-page")) {
            PageShell(
                kind: .private,
                header: PageHeader(user: user, navigation: .active(.spaces)),
                footer: PageFooter { EmptyFooterContent() }
            ) {
                SpaceTabs(space: space, active: .bots)
                AgentDetailIntro(space: space, bot: bot, placement: placement, isRunning: !runtime.isEmpty)
                if let error { p(.class("error page-error")) { error } }
                div(.class("detail-layout")) {
                    section(.class("detail-main")) {
                        if space.permissions.bots == .configure {
                            AgentEditor(space: space.id, id: bot.id.description, draft: draft, placement: placement)
                        } else {
                            AgentConfigurationSummary(bot: bot)
                        }
                    }
                    AgentRuntimeSummary(bot: bot, runtime: runtime)
                }
            }
        }
    }
}

/// The bot's name and model, how it's doing, and what can be done with it.
struct AgentDetailIntro: HTML, Sendable {
    let space: SpaceListing
    let bot: Bot
    let placement: AgentDetailPage.Placement
    let isRunning: Bool

    private var status: String { isRunning ? "active" : "idle" }
    private var path: String { "/spaces/\(space.id.rawValue.uuidString)" }

    var body: some HTML {
        section(.class("page-intro detail-page-intro")) {
            div {
                h1 { bot.name.rawValue }
                p(.class("lede")) { bot.modelIdentifier }
            }
            div(.class("detail-actions")) {
                span(.class("detail-status")) { status }
                if space.permissions.bots == .configure, case .additional = placement {
                    form(.method(.post), .action(path + "/bots/main")) {
                        input(.type(.hidden), .name("id"), .value(bot.id.description))
                        button(.type(.submit), .class("button button-secondary")) { "Make main" }
                    }
                }
                a(.href(path + "/chat/\(bot.id)"), .class("button button-accent")) { "Open chat" }
            }
        }
    }
}

/// The saved bot's form, for whoever may configure the space's bots, and deleting it unless it's the
/// main one.
struct AgentEditor: HTML, Sendable {
    let space: SpaceID
    let id: String
    let draft: AgentDraft
    let placement: AgentDetailPage.Placement

    private var path: String { "/spaces/\(space.rawValue.uuidString)/bots" }

    var body: some HTML {
        h2 { "Shape this bot" }
        p(.class("section-intro")) { "Choose its voice, its mind, and how it finds you." }
        p(.class("detail-note")) {
            "Changes apply from its next answer, in every conversation it's in."
        }
        AgentConfigurationForm(
            action: path + "/update", editing: .saved(id: id, in: space), draft: draft,
            submitLabel: "Save changes")
        if case .additional = placement {
            form(.method(.post), .action(path + "/delete"), .class("delete-form")) {
                input(.type(.hidden), .name("id"), .value(id))
                button(.type(.submit), .class("text-button text-button-danger")) { "Delete bot" }
            }
        }
    }
}

/// The bot's configuration, for someone who can't change it.
struct AgentConfigurationSummary: HTML, Sendable {
    let bot: Bot

    var body: some HTML {
        h2 { "Bot configuration" }
        p(.class("section-intro")) {
            "Only those who may configure this space's bots can change it. You can see how it's set up and chat with it."
        }
        div(.class("detail-note")) {
            p {
                strong { "Model" }
                bot.modelIdentifier
            }
            p {
                strong { "Context" }
                bot.model.location.contextWindow.map { "\($0.formatted()) tokens" }
                    ?? "The provider's own, which it doesn't say"
            }
        }
    }
}

extension Bot {
    /// Its model, as people read it: where it runs, then which.
    var modelIdentifier: String {
        (try? TurgaiModelPresentation.displayName(for: model.agentModel)) ?? model.name.rawValue
    }
}
