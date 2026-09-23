import AnyLanguageModel
import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import NIOCore
import TurgaiApplication
import TurgaiHail
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct AgentConfigurationForm: HTML, Sendable {
    let action: String
    let profile: TurgaiAgentProfile?
    let modelCatalog: TurgaiModelCatalog
    let submitLabel: String

    private var selectedModel: AgentModel? { profile?.model }

    var body: some HTML {
        form(.method(.post), .action(action), .class("config-form")) {
            if let profile { input(.type(.hidden), .name("id"), .value(profile.id)) }
            section(.class("config-group")) {
                h3 { "Identity" }
                label(.class("form-field")) {
                    span(.class("field-label")) { "Name" }
                    input(
                        .type(.text), .name("name"), .value(profile?.name ?? ""), .placeholder("A name for this bot"),
                        .required)
                }
            }
            section(.class("config-group")) {
                h3 { "Model" }
                ModelPicker(catalog: modelCatalog, selectedModel: selectedModel)
                label(.class("form-field")) {
                    span(.class("field-label")) { "Model endpoint" }
                    input(
                        .type(.url), .name("endpointURL"),
                        .value(
                            profile.flatMap { profile in
                                guard case .ollama(let baseURL) = profile.providerConfiguration else { return nil }
                                return baseURL.absoluteString
                            } ?? ""),
                        .placeholder(OllamaConfiguration.defaultBaseURL.absoluteString)
                    )
                    p(.class("hint")) { "Used by providers that need a configured endpoint." }
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
                    p(.class("hint")) { "Leave it at provider default unless this model supports a specific level." }
                }
                label(.class("form-field")) {
                    span(.class("field-label")) { "Context window" }
                    input(
                        .type(.number), .name("contextWindow"),
                        .value(String(profile?.contextWindow ?? TurgaiAgentProfileStore.defaultContextWindow)),
                        .required
                    )
                    p(.class("hint")) { "Maximum context passed to the model." }
                }
            }
            section(.class("config-group")) {
                h3 { "Behavior" }
                label(.class("form-field")) {
                    span(.class("field-label")) { "Persona" }
                    textarea(
                        .name("persona"), .init(name: "rows", value: "6"), .placeholder("How should this bot speak?")
                    ) {
                        profile?.persona ?? ""
                    }
                }
                label(.class("form-field")) {
                    span(.class("field-label")) { "Instructions" }
                    textarea(
                        .name("instructions"), .init(name: "rows", value: "5"),
                        .placeholder("What should this bot know or do?")
                    ) {
                        profile?.instructions ?? ""
                    }
                }
            }
            div(.class("form-actions")) {
                button(.type(.submit), .class("button button-accent")) { submitLabel }
                a(
                    .href(profile == nil ? "/" : "/agents/\(profile!.id)"),
                    .class("button button-secondary")
                ) { "Cancel" }
            }
        }
    }
}
