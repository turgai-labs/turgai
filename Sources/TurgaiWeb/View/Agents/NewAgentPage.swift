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
#else
    import Foundation
#endif

struct NewAgentPage: HTMLDocument, Sendable {
    let user: AuthenticatedUser
    /// The space it's a new bot of.
    let space: SpaceListing
    let draft: AgentDraft
    let error: String?

    init(
        user: AuthenticatedUser,
        space: SpaceListing,
        draft: AgentDraft,
        error: String? = nil
    ) {
        self.user = user
        self.space = space
        self.draft = draft
        self.error = error
    }

    var title: String { "Turgai — New bot" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("app-page")) {
            PageShell(
                kind: .private,
                header: PageHeader(user: user, navigation: .active(.spaces)),
                footer: PageFooter { EmptyFooterContent() }
            ) {
                SpaceTabs(space: space, active: .bots)
                section(.class("page-intro detail-page-intro")) {
                    div {
                        h1 { "Make a new companion" }
                        p(.class("lede")) { "Give it a voice, a mind, and a way to reach you." }
                    }
                }
                if let error { p(.class("error page-error")) { error } }
                section(.class("detail-main new-bot-main")) {
                    AgentConfigurationForm(
                        action: "/spaces/\(space.id.rawValue.uuidString)/bots/create",
                        editing: .new(in: space.id),
                        draft: draft,
                        submitLabel: "Create bot"
                    )
                }
            }
        }
    }
}
