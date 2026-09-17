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

struct AgentDetailPage: HTMLDocument, Sendable {
    let user: AuthenticatedUser
    let profile: TurgaiAgentProfile
    let modelCatalog: TurgaiModelCatalog
    let runtime: [TurgaiAgentRuntimeSnapshot]
    let isDefaultProfile: Bool
    let error: String?

    init(
        user: AuthenticatedUser,
        profile: TurgaiAgentProfile,
        modelCatalog: TurgaiModelCatalog,
        runtime: [TurgaiAgentRuntimeSnapshot] = [],
        isDefaultProfile: Bool,
        error: String? = nil
    ) {
        self.user = user
        self.profile = profile
        self.modelCatalog = modelCatalog
        self.runtime = runtime
        self.isDefaultProfile = isDefaultProfile
        self.error = error
    }

    var title: String { "Turgai — \(profile.name)" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("app-page")) {
            div(.class("app-shell")) {
                AppHeader(user: user, section: .bots)
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
                    span(.class("detail-status")) {
                        profile.enabled ? (runtime.isEmpty ? "idle" : "active") : "paused"
                    }
                }
                if let error { p(.class("error page-error")) { error } }
                div(.class("detail-layout")) {
                    section(.class("detail-main")) {
                        h2 { "Shape this bot" }
                        p(.class("section-intro")) { "Choose its voice, its mind, and how it finds you." }
                        p(.class("detail-note")) {
                            "Changes take effect the next time this bot starts. Conversations already underway keep their current voice."
                        }
                        AgentConfigurationForm(
                            action: "/agents/update",
                            profile: profile,
                            modelCatalog: modelCatalog,
                            submitLabel: "Save changes"
                        )
                        if !isDefaultProfile {
                            form(.method(.post), .action("/agents/delete"), .class("delete-form")) {
                                input(.type(.hidden), .name("id"), .value(profile.id))
                                button(.type(.submit), .class("text-button text-button-danger")) { "Delete bot" }
                            }
                        }
                    }
                    AgentRuntimeSummary(profile: profile, runtime: runtime)
                }
            }
        }
    }
}
