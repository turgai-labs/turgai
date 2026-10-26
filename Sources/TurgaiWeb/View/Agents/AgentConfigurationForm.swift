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

/// The agent form, filled from `draft`: for a new agent, or one already saved.
struct AgentConfigurationForm: HTML, Sendable {
    /// Which agent the form saves.
    enum Editing: Sendable, Equatable {
        case new
        case saved(id: String)
    }

    let action: String
    let editing: Editing
    let draft: AgentDraft
    let modelCatalog: TurgaiModelCatalog
    let submitLabel: String

    private var cancelHref: String {
        switch editing {
        case .new: "/"
        case .saved(let id): "/agents/\(id)"
        }
    }

    var body: some HTML {
        form(.method(.post), .action(action), .class("config-form")) {
            if case .saved(let id) = editing { input(.type(.hidden), .name("id"), .value(id)) }
            section(.class("config-group")) {
                h3 { "Identity" }
                label(.class("form-field")) {
                    span(.class("field-label")) { "Name" }
                    input(
                        .type(.text), .name("name"), .value(draft.name), .placeholder("A name for this bot"),
                        .required)
                }
            }
            section(.class("config-group")) {
                h3 { "Model" }
                ModelPicker(catalog: modelCatalog, provider: draft.provider, modelID: draft.modelID)
                ProviderConfigurationFields(provider: draft.provider, settings: draft.settings)
                ReasoningEffortField(selected: draft.reasoningEffort)
            }
            AgentBehaviorFields(persona: draft.persona, instructions: draft.instructions)
            div(.class("form-actions")) {
                button(.type(.submit), .class("button button-accent")) { submitLabel }
                a(.href(cancelHref), .class("button button-secondary")) { "Cancel" }
            }
        }
    }
}

/// How the agent speaks, and what it's told.
struct AgentBehaviorFields: HTML, Sendable {
    let persona: String
    let instructions: String

    var body: some HTML {
        section(.class("config-group")) {
            h3 { "Behavior" }
            label(.class("form-field")) {
                span(.class("field-label")) { "Persona" }
                textarea(.name("persona"), .init(name: "rows", value: "6"), .placeholder("How should this bot speak?")) {
                    persona
                }
            }
            label(.class("form-field")) {
                span(.class("field-label")) { "Instructions" }
                textarea(
                    .name("instructions"), .init(name: "rows", value: "5"),
                    .placeholder("What should this bot know or do?")
                ) {
                    instructions
                }
            }
        }
    }
}
