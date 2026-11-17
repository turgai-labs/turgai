import Elementary
import TurgaiDomain

/// Making a space: its name, and its first bot, its main.
struct NewSpacePage: HTMLDocument, Sendable {
    let user: AuthenticatedUser
    /// Its name, as written.
    let name: String
    let draft: AgentDraft
    let error: String?

    init(user: AuthenticatedUser, name: String, draft: AgentDraft, error: String? = nil) {
        self.user = user
        self.name = name
        self.draft = draft
        self.error = error
    }

    var title: String { "Turgai — New space" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("app-page")) {
            PageShell(
                kind: .private,
                header: PageHeader(user: user, navigation: .active(.spaces)),
                footer: PageFooter { EmptyFooterContent() }
            ) {
                section(.class("page-intro detail-page-intro")) {
                    div {
                        TurgaiBreadcrumb(parentTitle: "Spaces", parentHref: "/", currentTitle: "New space")
                        h1 { "Make a space" }
                        p(.class("lede")) { "Name it, and give it its first bot." }
                    }
                }
                if let error { p(.class("error page-error")) { error } }
                section(.class("detail-main new-bot-main")) {
                    AgentConfigurationForm(
                        action: "/spaces/new", editing: .newSpace(name: name), draft: draft,
                        submitLabel: "Make space")
                }
            }
        }
    }
}
