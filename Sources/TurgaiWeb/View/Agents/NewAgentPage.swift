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

struct NewAgentPage: HTMLDocument, Sendable {
    let user: AuthenticatedUser
    let modelCatalog: TurgaiModelCatalog
    let error: String?

    init(
        user: AuthenticatedUser,
        modelCatalog: TurgaiModelCatalog,
        error: String? = nil
    ) {
        self.user = user
        self.modelCatalog = modelCatalog
        self.error = error
    }

    var title: String { "Turgai — New bot" }
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
                            currentTitle: "New bot"
                        )
                        h1 { "Make a new companion" }
                        p(.class("lede")) { "Give it a voice, a mind, and a way to reach you." }
                    }
                }
                if let error { p(.class("error page-error")) { error } }
                section(.class("detail-main new-bot-main")) {
                    AgentConfigurationForm(
                        action: "/agents/create",
                        profile: nil,
                        modelCatalog: modelCatalog,
                        submitLabel: "Create bot"
                    )
                }
            }
        }
    }
}
