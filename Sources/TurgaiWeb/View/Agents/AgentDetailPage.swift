import AnyLanguageModel
import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import NIOCore
import TurgaiApplication
import TurgaiHail
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
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
    let modelCatalog: TurgaiModelCatalog
    let runtime: [TurgaiAgentRuntimeSnapshot]
    let placement: Placement
    let requestLimit: Int?
    let error: String?

    init(
        user: AuthenticatedUser,
        profile: TurgaiAgentProfile,
        modelCatalog: TurgaiModelCatalog,
        runtime: [TurgaiAgentRuntimeSnapshot] = [],
        placement: Placement,
        requestLimit: Int? = nil,
        error: String? = nil
    ) {
        self.user = user
        self.profile = profile
        self.modelCatalog = modelCatalog
        self.runtime = runtime
        self.placement = placement
        self.requestLimit = requestLimit
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
                section(.class("page-intro detail-page-intro")) {
                    div {
                        TurgaiBreadcrumb(
                            parentTitle: "Bots",
                            parentHref: "/",
                            currentTitle: "Edit bot"
                        )
                        h1 { profile.name }
                        p(.class("lede")) { profile.model.identifier }
                    }
                    div(.class("detail-actions")) {
                        span(.class("detail-status")) {
                            switch profile.availability {
                            case .enabled: runtime.isEmpty ? "idle" : "active"
                            case .disabled: "paused"
                            }
                        }
                        switch (user, placement) {
                        case (.administrator, .additional):
                            form(.method(.post), .action("/agents/default")) {
                                input(.type(.hidden), .name("id"), .value(profile.id))
                                button(.type(.submit), .class("button button-secondary")) { "Make default" }
                            }
                        case (.user, _), (.member, _), (.administrator, .default):
                            EmptyHTML()
                        }
                        a(.href("/chat/\(profile.id)"), .class("button button-accent")) { "Open chat" }
                    }
                }
                if let error { p(.class("error page-error")) { error } }
                div(.class("detail-layout")) {
                    section(.class("detail-main")) {
                        switch user {
                        case .administrator:
                            h2 { "Shape this bot" }
                            p(.class("section-intro")) { "Choose its voice, its mind, and how it finds you." }
                            p(.class("detail-note")) {
                                "Changes take effect the next time this bot starts. Conversations already underway keep their current voice."
                            }
                            AgentConfigurationForm(
                                action: "/agents/update",
                                profile: profile,
                                modelCatalog: modelCatalog,
                                submitLabel: "Save changes",
                                requestLimit: requestLimit
                            )
                            if case .additional = placement {
                                form(.method(.post), .action("/agents/delete"), .class("delete-form")) {
                                    input(.type(.hidden), .name("id"), .value(profile.id))
                                    button(.type(.submit), .class("text-button text-button-danger")) { "Delete bot" }
                                }
                            }
                        case .user, .member:
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
                                    profile.persona?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                                        ? profile.persona!
                                        : "No persona configured"
                                }
                            }
                        }
                    }
                    AgentRuntimeSummary(profile: profile, runtime: runtime)
                }
            }
        }
    }
}
