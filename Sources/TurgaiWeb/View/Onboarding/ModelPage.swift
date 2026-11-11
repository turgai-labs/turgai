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

struct ModelPage: HTMLDocument, Sendable {
    let draft: AgentDraft
    /// The bot being set up, once it's saved.
    let profileID: String?
    let error: String?

    init(
        draft: AgentDraft,
        profileID: String?,
        error: String? = nil
    ) {
        self.draft = draft
        self.profileID = profileID
        self.error = error
    }
    var title: String { "Turgai — Model" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("setup-page")) {
            PageShell(
                kind: .setup,
                header: PageHeader(),
                footer: PageFooter {
                    SetupFooterContent(
                        step: 3,
                        backHref: "/onboarding/register",
                        submitFormID: "model-form",
                        submitLabel: "Continue"
                    )
                },
            ) {
                section(.class("setup-content")) {
                    div(.class("setup-copy")) {
                        p(.class("eyebrow")) { "The mind" }
                        h1 { "Give Turgai a mind." }
                        p(.class("lede")) {
                            "Choose the model behind your companion. You can change its voice and direction later."
                        }
                        div(.class("setup-form-area")) {
                            if let error { p(.class("error")) { error } }
                            modelForm
                        }
                    }
                }
            }
        }
    }

    @HTMLBuilder private var modelForm: some HTML & Sendable {
        form(.method(.post), .action("/onboarding/model"), .init(name: "id", value: "model-form")) {
            // The provider, how it's reached, then its model, and how much it's given.
            ProviderPicker(provider: draft.provider, profileID: profileID)
            ProviderConfigurationFields(
                provider: draft.provider, settings: draft.settings, profileID: profileID, part: .reaching)
            ModelPicker(modelID: draft.modelID, profileID: profileID)
            ReasoningEffortField(selected: draft.reasoningEffort)
            ProviderConfigurationFields(
                provider: draft.provider, settings: draft.settings, profileID: profileID, part: .tuning)
            AgentCharacterFields(name: draft.name, persona: draft.persona, instructions: draft.instructions)
        }
    }

}

/// The new bot's name, how it speaks, and what guides it.
struct AgentCharacterFields: HTML, Sendable {
    let name: String
    let persona: String
    let instructions: String

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Bot name" }
            input(.type(.text), .name("name"), .value(name), .required)
        }
        label(.class("form-field")) {
            span(.class("field-label")) { "Voice" }
            textarea(.name("persona"), .init(name: "rows", value: "6")) { persona }
            p(.class("hint")) { "Describe how you want Turgai to speak." }
        }
        label(.class("form-field")) {
            span(.class("field-label")) { "Guidance" }
            textarea(.name("instructions"), .init(name: "rows", value: "4")) { instructions }
        }
    }
}
