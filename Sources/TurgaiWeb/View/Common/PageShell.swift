import Elementary

enum PageShellKind: Sendable {
    case setup
    case `private`
    case `public`
}

enum PageContentLayout: Sendable {
    case flow
    case overlayScroll
}

enum PageFooterBehavior: Sendable {
    case normal
    case sticky
}

struct PageContent<Content: HTML & Sendable>: HTML, Sendable {
    let content: Content

    init(@HTMLBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some HTML {
        div(.class("page-content")) {
            content
        }
    }
}

struct PageShell<Content: HTML & Sendable, Footer: HTML & Sendable>: HTML, Sendable {
    let kind: PageShellKind
    let contentLayout: PageContentLayout
    let header: PageHeader
    let footer: Footer
    let content: PageContent<Content>

    init(
        kind: PageShellKind,
        contentLayout: PageContentLayout = .flow,
        header: PageHeader,
        footer: Footer,
        @HTMLBuilder content: () -> Content
    ) {
        self.kind = kind
        self.contentLayout = contentLayout
        self.header = header
        self.footer = footer
        self.content = PageContent(content: content)
    }

    var body: some HTML {
        div(.class("page-shell \(kind.cssClass) \(contentLayout.cssClass)")) {
            header
            content
            footer
        }
    }
}

extension PageContentLayout {
    fileprivate var cssClass: String {
        switch self {
        case .flow:
            "flow-layout"
        case .overlayScroll:
            "overlay-scroll-layout"
        }
    }
}

extension PageShellKind {
    fileprivate var cssClass: String {
        switch self {
        case .private:
            "app-shell"
        case .setup:
            "setup-shell"
        case .public:
            "chat-shell chat-shell-standalone"
        }
    }
}
