import AnyLanguageModel
import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import NIOCore
import TurgaiApplication
import TurgaiCalls
import TurgaiHail
import TurgaiPersistence
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct TurgaiToolsPage: HTMLDocument, Sendable {
    let user: AuthenticatedUser
    let documents: [UserToolDocument]
    let error: String?

    init(
        user: AuthenticatedUser,
        documents: [UserToolDocument],
        error: String? = nil
    ) {
        self.user = user
        self.documents = documents
        self.error = error
    }

    var title: String { "Turgai — Tools" }
    var head: some HTML { TurgaiHead() }

    private var toolAccess: TurgaiToolRow.Access {
        switch user {
        case .user, .member: .view
        case .administrator: .edit
        }
    }

    var body: some HTML {
        main(.class("app-page")) {
            PageShell(
                kind: .private,
                header: PageHeader(user: user, navigation: .active(.tools)),
                footer: PageFooter { EmptyFooterContent() }
            ) {
                ToolsIntro(user: user)
                if let error {
                    p(.class("error page-error")) { error }
                }
                if documents.isEmpty {
                    NoTools(user: user)
                } else {
                    section(.class("tools-list")) {
                        for document in documents {
                            TurgaiToolRow(
                                document: document,
                                access: toolAccess
                            )
                        }
                    }
                }
            }
        }
    }
}

/// What tools are, and New tool for an administrator.
private struct ToolsIntro: HTML, Sendable {
    let user: AuthenticatedUser

    var body: some HTML {
        section(.class("page-intro")) {
            div {
                p(.class("eyebrow")) { "Your capabilities" }
                h1 { "Tools" }
                p(.class("lede")) {
                    "Give your bots useful abilities, one clear step at a time."
                }
            }
            if case .administrator = user {
                a(.href("/tools/new"), .class("button button-accent add-tool-link")) { "+ New tool" }
            }
        }
    }
}

/// What there is with no tools yet: the first to make, for an administrator.
private struct NoTools: HTML, Sendable {
    let user: AuthenticatedUser

    var body: some HTML {
        div(.class("empty-state")) {
            p(.class("eyebrow")) { "A blank canvas" }
            h2 { "Start with one useful ability." }
            p(.class("section-intro")) {
                "Fetch information, run a script, or ask another bot to take on one focused piece of thinking."
            }
            if case .administrator = user {
                a(.href("/tools/new"), .class("text-link")) { "New tool →" }
            }
        }
    }
}
