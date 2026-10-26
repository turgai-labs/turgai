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

struct OnboardingPage: HTMLDocument, Sendable {
    var title: String { "Turgai — Welcome" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("setup-page")) {
            PageShell(
                kind: .setup,
                header: PageHeader(),
                footer: PageFooter {
                    SetupFooterContent(step: 1, forwardHref: "/onboarding/register", forwardLabel: "Let’s begin")
                }
            ) {
                section(.class("setup-content setup-content-hero")) {
                    SetupIntro(
                        eyebrow: "Start here", title: "Make capable help your own.",
                        lede: "A few choices shape how Turgai works with you. You can change them later.")
                    WelcomeArt()
                }
            }
        }
    }
}

/// The welcome page's picture, and what starting here means.
struct WelcomeArt: HTML, Sendable {
    var body: some HTML {
        div(.class("setup-form-area setup-welcome-area")) {
            div(.class("setup-hero-art"), .init(name: "aria-hidden", value: "true")) {
                span(.class("geometry geometry-blue")) {}
                span(.class("geometry geometry-coral")) {}
                span(.class("geometry geometry-yellow")) {}
                img(.src("/skylark.svg"), .alt(""))
                span(.class("hero-art-caption")) { "small bird / wide horizon" }
            }
            div(.class("setup-note")) {
                p(.class("field-label")) { "Yours from the start" }
                p { "This is your private starting point." }
                p(.class("hint")) { "Shape the rest as you go." }
            }
        }
    }
}
