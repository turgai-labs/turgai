import Elementary
import TurgaiDomain
import TurgaiSpaces

/// A space's name, back to your spaces, and its pages: its bots, its connections for whoever may
/// configure them, and chatting in it.
struct SpaceTabs: HTML, Sendable {
    enum Tab: Sendable {
        case bots
        case connections
        case chat
    }

    let space: SpaceListing
    let active: Tab

    private var path: String { "/spaces/\(space.id.rawValue.uuidString)" }

    var body: some HTML {
        div(.class("space-tabs")) {
            TurgaiBreadcrumb(parentTitle: "Spaces", parentHref: "/", currentTitle: space.name.rawValue)
            nav(.class("app-nav-links"), .init(name: "aria-label", value: space.name.rawValue)) {
                SpaceTabLink(href: path, label: "Bots", isActive: active == .bots)
                if space.permissions.connections {
                    SpaceTabLink(href: path + "/connections", label: "Connections", isActive: active == .connections)
                }
                SpaceTabLink(href: path + "/chat", label: "Chat", isActive: active == .chat)
            }
        }
    }
}

private struct SpaceTabLink: HTML, Sendable {
    let href: String
    let label: String
    let isActive: Bool

    var body: some HTML {
        a(
            .href(href),
            .class(isActive ? "nav-link nav-link-active" : "nav-link"),
            .init(name: "aria-current", value: isActive ? "page" : nil)
        ) {
            label
        }
    }
}
