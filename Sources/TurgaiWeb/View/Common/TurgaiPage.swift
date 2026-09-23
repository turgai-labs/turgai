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

struct TurgaiPage: HTMLDocument, Sendable {
    let title: String
    let user: AuthenticatedUser
    let profiles: [BotCard]
    let runtime: [TurgaiAgentRuntimeSnapshot]
    let error: String?

    init(
        title: String,
        user: AuthenticatedUser,
        profiles: [BotCard],
        runtime: [TurgaiAgentRuntimeSnapshot] = [],
        error: String? = nil
    ) {
        self.title = title
        self.user = user
        self.profiles = profiles
        self.runtime = runtime
        self.error = error
    }

    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("app-page")) {
            PageShell(
                kind: .private,
                header: PageHeader(user: user, navigation: .active(.bots)),
                footer: PageFooter { EmptyFooterContent() }
            ) {
                section(.class("page-intro")) {
                    div {
                        p(.class("eyebrow")) { "Your Turgai" }
                        h1 { "Bots" }
                        p(.class("lede")) { "Choose a bot to open its conversations and shape how it works." }
                    }
                    a(.href("/agents/new"), .class("button button-accent")) { "+ New bot" }
                }
                if let error { p(.class("error page-error")) { error } }
                if profiles.isEmpty {
                    div(.class("empty-state")) {
                        p(.class("eyebrow")) { "A clear sky" }
                        h2 { "Give Turgai its first companion." }
                        a(.href("/agents/new"), .class("button button-accent")) { "+ New bot" }
                    }
                } else {
                    section(.class("bot-grid")) {
                        for profile in profiles {
                            AgentTile(
                                profile: profile,
                                runtime: runtime.filter { $0.profileID == profile.id }
                            )
                        }
                    }
                }
            }
            HTMLRaw(
                """
                <script>
                (() => {
                    const refreshAgents = async () => {
                        try {
                            const response = await fetch("/api/agents", {
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
            )
        }
    }
}
