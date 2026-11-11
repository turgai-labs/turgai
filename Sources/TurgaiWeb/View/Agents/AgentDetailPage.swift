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

#if canImport(FoundationEssentials)
    import FoundationEssentials
    import FoundationInternationalization
#else
    import Foundation
#endif

struct AgentDetailPage: HTMLDocument, Sendable {
    enum Placement: Sendable {
        case `default`
        case additional
    }

    let user: AuthenticatedUser
    let profile: TurgaiAgentProfile
    /// The form's values: the saved profile, or what was submitted when saving failed.
    let draft: AgentDraft
    let runtime: [TurgaiAgentRuntimeSnapshot]
    let placement: Placement
    let error: String?

    init(
        user: AuthenticatedUser,
        profile: TurgaiAgentProfile,
        draft: AgentDraft,
        runtime: [TurgaiAgentRuntimeSnapshot] = [],
        placement: Placement,
        error: String? = nil
    ) {
        self.user = user
        self.profile = profile
        self.draft = draft
        self.runtime = runtime
        self.placement = placement
        self.error = error
    }

    var title: String { "Turgai — \(profile.name)" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("app-page")) {
            PageShell(
                kind: .private,
                header: PageHeader(user: user, navigation: .active(.bots)),
                footer: PageFooter { EmptyFooterContent() }
            ) {
                AgentDetailIntro(user: user, profile: profile, placement: placement, isRunning: !runtime.isEmpty)
                if let error { p(.class("error page-error")) { error } }
                div(.class("detail-layout")) {
                    section(.class("detail-main")) {
                        switch user {
                        case .administrator:
                            AgentEditor(
                                id: profile.id, draft: draft, placement: placement)
                        case .user, .member:
                            AgentConfigurationSummary(profile: profile)
                        }
                    }
                    AgentRuntimeSummary(profile: profile, runtime: runtime)
                }
            }
        }
    }
}

/// The agent's name and model, how it's doing, and what can be done with it.
struct AgentDetailIntro: HTML, Sendable {
    let user: AuthenticatedUser
    let profile: TurgaiAgentProfile
    let placement: AgentDetailPage.Placement
    let isRunning: Bool

    private var status: String {
        switch profile.availability {
        case .enabled: isRunning ? "active" : "idle"
        case .disabled: "paused"
        }
    }

    var body: some HTML {
        section(.class("page-intro detail-page-intro")) {
            div {
                TurgaiBreadcrumb(parentTitle: "Bots", parentHref: "/", currentTitle: "Edit bot")
                h1 { profile.name }
                p(.class("lede")) { profile.model.identifier }
            }
            div(.class("detail-actions")) {
                span(.class("detail-status")) { status }
                if case (.administrator, .additional) = (user, placement) {
                    form(.method(.post), .action("/agents/default")) {
                        input(.type(.hidden), .name("id"), .value(profile.id))
                        button(.type(.submit), .class("button button-secondary")) { "Make default" }
                    }
                }
                a(.href("/chat/\(profile.id)"), .class("button button-accent")) { "Open chat" }
            }
        }
    }
}

/// The saved agent's form, for an administrator, and deleting it unless it's the default.
struct AgentEditor: HTML, Sendable {
    let id: String
    let draft: AgentDraft
    let placement: AgentDetailPage.Placement

    var body: some HTML {
        h2 { "Shape this bot" }
        p(.class("section-intro")) { "Choose its voice, its mind, and how it finds you." }
        p(.class("detail-note")) {
            "Changes take effect the next time this bot starts. Conversations already underway keep their current voice."
        }
        AgentConfigurationForm(
            action: "/agents/update", editing: .saved(id: id), draft: draft,
            submitLabel: "Save changes")
        if case .additional = placement {
            form(.method(.post), .action("/agents/delete"), .class("delete-form")) {
                input(.type(.hidden), .name("id"), .value(id))
                button(.type(.submit), .class("text-button text-button-danger")) { "Delete bot" }
            }
        }
    }
}

/// The agent's configuration, for someone who can't change it.
struct AgentConfigurationSummary: HTML, Sendable {
    let profile: TurgaiAgentProfile

    private var persona: String {
        let persona = (profile.persona ?? "").trimmed()
        return persona.isEmpty ? "No persona configured" : persona
    }

    var body: some HTML {
        h2 { "Bot configuration" }
        p(.class("section-intro")) {
            "Only administrators can change this bot. You can inspect its configuration and open a conversation."
        }
        div(.class("detail-note")) {
            p {
                strong { "Model" }
                profile.model.identifier
            }
            p {
                strong { "Context" }
                "\(profile.contextWindow.formatted()) tokens"
            }
            p {
                strong { "Persona" }
                persona
            }
        }
    }
}
