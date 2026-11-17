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
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A space's bots, each to open, with how it's doing; adding one, for whoever may configure them.
struct SpacePage: HTMLDocument, Sendable {
    let user: AuthenticatedUser
    let space: SpaceListing
    let profiles: [BotCard]
    let runtime: [TurgaiAgentRuntimeSnapshot]

    private var path: String { "/spaces/\(space.id.rawValue.uuidString)" }
    private var configures: Bool { space.permissions.bots == .configure }

    var title: String { "Turgai — \(space.name)" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("app-page")) {
            PageShell(
                kind: .private,
                header: PageHeader(user: user, navigation: .active(.spaces)),
                footer: PageFooter { EmptyFooterContent() }
            ) {
                SpaceTabs(space: space, active: .bots)
                section(.class("page-intro")) {
                    div {
                        h1 { "Bots" }
                        p(.class("lede")) { "Choose a bot to chat with it and see how it works." }
                    }
                    if configures { a(.href(path + "/bots/new"), .class("button button-accent")) { "+ New bot" } }
                }
                section(.class("bot-grid")) {
                    for profile in profiles {
                        AgentTile(space: space.id, profile: profile, runtime: runtime(of: profile))
                    }
                }
            }
            HTMLRaw(refreshScript)
        }
    }

    /// What `profile`'s agent is running now.
    private func runtime(of profile: BotCard) -> [TurgaiAgentRuntimeSnapshot] {
        runtime.filter { (snapshot: TurgaiAgentRuntimeSnapshot) -> Bool in snapshot.profileID == profile.id }
    }

    /// Refreshes each bot's status every five seconds.
    private var refreshScript: String {
        """
        <script>
        (() => {
            const refreshAgents = async () => {
                try {
                    const response = await fetch("\(path)/runtime", {
                        credentials: "same-origin",
                        headers: { "Accept": "application/json" }
                    });
                    if (!response.ok) return;
                    const snapshot = await response.json();
                    for (const card of document.querySelectorAll("[data-agent-id]")) {
                        const profileID = card.dataset.agentId;
                        const active = snapshot.runtime.find(item => item.profileID === profileID);
                        const status = card.querySelector("[data-runtime-status]");
                        if (status) status.textContent = active ? active.phase : "idle";
                    }
                } catch (_) {
                    // A status refresh must never disturb the agent.
                }
            };
            refreshAgents();
            window.setInterval(refreshAgents, 5000);
        })();
        </script>
        """
    }
}
