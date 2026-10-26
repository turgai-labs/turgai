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

struct NewAgentPage: HTMLDocument, Sendable {
    let user: AuthenticatedUser
    let modelCatalog: TurgaiModelCatalog
    let draft: AgentDraft
    let error: String?

    init(
        user: AuthenticatedUser,
        modelCatalog: TurgaiModelCatalog,
        draft: AgentDraft,
        error: String? = nil
    ) {
        self.user = user
        self.modelCatalog = modelCatalog
        self.draft = draft
        self.error = error
    }

    var title: String { "Turgai — New bot" }
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
                        editing: .new,
                        draft: draft,
                        modelCatalog: modelCatalog,
                        submitLabel: "Create bot"
                    )
                }
            }
        }
    }
}
