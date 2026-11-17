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
    /// The first space's name, as written.
    let spaceName: String
    let draft: AgentDraft
    /// The bot being set up, once it's saved.
    let profileID: String?
    let error: String?

    init(
        spaceName: String,
        draft: AgentDraft,
        profileID: String?,
        error: String? = nil
    ) {
        self.spaceName = spaceName
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
                        step: 4,
                        backHref: "/onboarding/storage",
                        submitFormID: "model-form",
                        submitLabel: "Continue"
                    )
                },
            ) {
                section(.class("setup-content")) {
                    div(.class("setup-copy")) {
                        p(.class("eyebrow")) { "The first space" }
                        h1 { "Make your first space." }
                        p(.class("lede")) {
                            "Name it, and choose the model behind its first bot. You can change both later."
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
            label(.class("form-field")) {
                span(.class("field-label")) { "Space name" }
                input(
                    .type(.text), .name("spaceName"), .value(spaceName), .placeholder("Family, Work, …"), .required)
            }
            // The provider, how it's reached, then its model, and how much it's given.
            ProviderPicker(provider: draft.provider, profileID: profileID, asking: .setup)
            ProviderConfigurationFields(
                provider: draft.provider, settings: draft.settings, profileID: profileID, asking: .setup, part: .reaching)
            ModelPicker(modelID: draft.modelID, profileID: profileID, asking: .setup)
            ProviderConfigurationFields(
                provider: draft.provider, settings: draft.settings, profileID: profileID, asking: .setup, part: .tuning)
            AgentCharacterFields(name: draft.name, instructions: draft.instructions)
        }
    }

}

/// The new bot's name, and what guides it.
struct AgentCharacterFields: HTML, Sendable {
    let name: String
    let instructions: String

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Bot name" }
            input(.type(.text), .name("name"), .value(name), .required)
        }
        label(.class("form-field")) {
            span(.class("field-label")) { "Guidance" }
            textarea(.name("instructions"), .init(name: "rows", value: "4")) { instructions }
        }
    }
}
