import Elementary
import TurgaiDomain
import TurgaiSpaces

/// The spaces you're in, each to open, and making a new one: kept as they are, as you join one,
/// leave one, or one's renamed or archived.
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
                div(.id("spaces")) {
                    if spaces.isEmpty {
                        NoSpaces()
                    } else {
                        section(.class("bot-grid")) {
                            for space in spaces { SpaceTile(space: space) }
                        }
                    }
                }
            }
            script { HTMLRaw(Self.following) }
        }
    }

    /// Follows the person's spaces on the app's connection, joining them as it opens: each change to
    /// them, the list shown again as the server lists it now. It asks nothing else, so one ref does.
    static let following = """
        (() => {
          const shown = document.getElementById('spaces');
          const relist = async () => {
            const page = await fetch(location.pathname, { credentials: 'same-origin' });
            if (!page.ok) return;
            const listed = new DOMParser().parseFromString(await page.text(), 'text/html').getElementById('spaces');
            if (listed) shown.replaceChildren(...listed.childNodes);
          };
          const follow = () => {
            const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
            const socket = new WebSocket(`${scheme}://${location.host}/api/v1/live`);
            socket.addEventListener('open', () => socket.send(JSON.stringify({
              type: 'push', ref: { rawValue: '00000000-0000-0000-0000-000000000001' }, ask: 'join', topic: 'spaces'
            })));
            socket.addEventListener('message', (message) => {
              const event = JSON.parse(message.data);
              if (typeof event.type === 'string' && event.type.startsWith('space.')) relist();
            });
            // Followed again a moment after it closes: what changed meanwhile is read then.
            socket.addEventListener('close', () => setTimeout(() => { relist(); follow(); }, 2000));
          };
          follow();
        })();
        """
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
