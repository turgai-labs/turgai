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
    let modelCatalog: TurgaiModelCatalog
    let profile: TurgaiAgentProfile?
    let error: String?

    init(
        modelCatalog: TurgaiModelCatalog,
        profile: TurgaiAgentProfile? = nil,
        error: String? = nil
    ) {
        self.modelCatalog = modelCatalog
        self.profile = profile
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
                            form(
                                .method(.post), .action("/onboarding/model"),
                                .init(name: "id", value: "model-form")
                            ) {
                                ModelPicker(
                                    catalog: modelCatalog,
                                    selectedModel: Self.selectedModel(from: profile)
                                )
                                label(.class("form-field")) {
                                    span(.class("field-label")) { "Model endpoint" }
                                    input(
                                        .type(.url), .name("endpointURL"),
                                        .value(
                                            profile.flatMap { profile in
                                                guard case .ollama(let baseURL) = profile.providerConfiguration else {
                                                    return nil
                                                }
                                                return baseURL.absoluteString
                                            }
                                                ?? OllamaConfiguration.defaultBaseURL.absoluteString
                                        ),
                                        .placeholder(OllamaConfiguration.defaultBaseURL.absoluteString)
                                    )
                                    p(.class("hint")) { "Only needed for providers that use a remote endpoint." }
                                }
                                label(.class("form-field")) {
                                    span(.class("field-label")) { "Reasoning effort" }
                                    select(.name("reasoningEffort")) {
                                        if profile?.reasoningEffort == nil {
                                            option(.value(""), .selected) { "Provider default" }
                                        } else {
                                            option(.value("")) { "Provider default" }
                                        }
                                        for effort in [
                                            ReasoningEffort.none,
                                            .minimal,
                                            .low,
                                            .medium,
                                            .high,
                                            .xhigh,
                                            .max,
                                        ] {
                                            if profile?.reasoningEffort == effort {
                                                option(.value(effort.rawValue), .selected) { effort.rawValue }
                                            } else {
                                                option(.value(effort.rawValue)) { effort.rawValue }
                                            }
                                        }
                                    }
                                    p(.class("hint")) {
                                        "Leave it at provider default unless this model supports a specific level."
                                    }
                                }
                                label(.class("form-field")) {
                                    span(.class("field-label")) { "Bot name" }
                                    input(
                                        .type(.text), .name("agentName"), .value(profile?.name ?? "Turgai"),
                                        .required
                                    )
                                }
                                label(.class("form-field")) {
                                    span(.class("field-label")) { "Voice" }
                                    textarea(.name("persona"), .init(name: "rows", value: "6")) {
                                        profile?.persona ?? ""
                                    }
                                    p(.class("hint")) { "Describe how you want Turgai to speak." }
                                }
                                label(.class("form-field")) {
                                    span(.class("field-label")) { "Working memory" }
                                    input(
                                        .type(.number), .name("contextWindow"),
                                        .value(
                                            String(
                                                profile?.contextWindow ?? TurgaiAgentProfileStore.defaultContextWindow)),
                                        .required
                                    )
                                }
                                label(.class("form-field")) {
                                    span(.class("field-label")) { "Guidance" }
                                    textarea(.name("instructions"), .init(name: "rows", value: "4")) {
                                        profile?.instructions ?? ""
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

    }

    private static func selectedModel(from profile: TurgaiAgentProfile?) -> AgentModel? {
        profile?.model
    }
}
