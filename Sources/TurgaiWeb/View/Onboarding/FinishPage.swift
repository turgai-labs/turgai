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

struct FinishPage: HTMLDocument, Sendable {
    var title: String { "Turgai — Ready" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("setup-page")) {
            PageShell(
                kind: .setup,
                header: PageHeader(),
                footer: PageFooter {
                    SetupFooterContent(
                        step: 5,
                        backHref: "/onboarding/model",
                        submitFormID: "finish-form",
                        submitLabel: "Start Turgai"
                    )
                }
            ) {
                section(.class("setup-content")) {
                    div(.class("setup-copy")) {
                        p(.class("eyebrow")) { "Ready when you are" }
                        h1 { "Your Turgai is ready." }
                        p(.class("lede")) {
                            "Everything is in place. Start a conversation, then shape it as you go."
                        }
                    }
                    div(.class("setup-form-area setup-welcome-area")) {
                        form(
                            .method(.post), .action("/onboarding/finish"),
                            .init(name: "id", value: "finish-form")
                        ) {}
                    }
                }
            }
        }
    }
}

/// What setting up shows once it's done, while Turgai starts: it goes on to Turgai as soon as it
/// answers.
struct StartingPage: HTMLDocument, Sendable {
    var title: String { "Turgai — Starting" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("setup-page")) {
            PageShell(kind: .setup, header: PageHeader(), footer: PageFooter {}) {
                section(.class("setup-content")) {
                    div(.class("setup-copy")) {
                        p(.class("eyebrow")) { "Starting" }
                        h1 { "Turgai is starting." }
                        p(.class("lede")) { "It opens here in a moment." }
                    }
                }
            }
            HTMLRaw(Self.waitScript)
        }
    }

    /// Asks whether Turgai is set up and running, every second, and opens it once it says so:
    /// while it starts, nothing answers.
    private static let waitScript = """
        <script>
        (() => {
            const wait = async () => {
                try {
                    const response = await fetch("/api/v1/status", { headers: { "Accept": "application/json" } });
                    if (response.ok && (await response.json()).setup === "complete") {
                        window.location.assign("/");
                        return;
                    }
                } catch (_) {}
                setTimeout(wait, 1000);
            };
            setTimeout(wait, 1000);
        })();
        </script>
        """
}
