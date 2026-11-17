import Elementary
import TurgaiDomain
import TurgaiSpaces

/// The spaces you're in, each to open, and making a new one.
struct SpacesPage: HTMLDocument, Sendable {
    let user: AuthenticatedUser
    let spaces: [SpaceListing]

    var title: String { "Turgai — Spaces" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("app-page")) {
            PageShell(
                kind: .private,
                header: PageHeader(user: user, navigation: .active(.spaces)),
                footer: PageFooter { EmptyFooterContent() }
            ) {
                section(.class("page-intro")) {
                    div {
                        p(.class("eyebrow")) { "Your Turgai" }
                        h1 { "Spaces" }
                        p(.class("lede")) { "Each space has its people, its bots and its connections." }
                    }
                    a(.href("/spaces/new"), .class("button button-accent")) { "+ New space" }
                }
                if spaces.isEmpty {
                    NoSpaces()
                } else {
                    section(.class("bot-grid")) {
                        for space in spaces { SpaceTile(space: space) }
                    }
                }
            }
        }
    }
}

/// One space, to open.
struct SpaceTile: HTML, Sendable {
    let space: SpaceListing

    private var initial: String {
        space.name.rawValue.first.map { String($0).uppercased() } ?? "?"
    }

    var body: some HTML {
        a(.href("/spaces/\(space.id.rawValue.uuidString)"), .class("bot-tile")) {
            div(.class("bot-tile-top")) {
                span(.class("bot-mark")) { initial }
            }
            h2 { space.name.rawValue }
            div(.class("bot-tile-bottom")) {
                span { space.status == .archived ? "Archived" : "Open" }
                span(.class("tile-arrow")) { "→" }
            }
        }
    }
}

/// What the spaces page shows before you're in any.
private struct NoSpaces: HTML, Sendable {
    var body: some HTML {
        div(.class("empty-state")) {
            p(.class("eyebrow")) { "No spaces yet" }
            h2 { "Make a space, or open an invite to one." }
            a(.href("/spaces/new"), .class("button button-accent")) { "+ New space" }
        }
    }
}
