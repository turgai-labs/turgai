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

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A bot's form, filled from `draft`: a new space's first bot, a new bot of a space, or one saved
/// there.
struct AgentConfigurationForm: HTML, Sendable {
    /// Which bot the form saves.
    enum Editing: Sendable, Equatable {
        /// A new space's first bot, with the space's name as written.
        case newSpace(name: String)
        /// A new bot of `space`.
        case new(in: SpaceID)
        /// The bot `id` of `space`.
        case saved(id: String, in: SpaceID)
    }

    let action: String
    let editing: Editing
    let draft: AgentDraft
    let submitLabel: String

    /// The saved bot's id, when it's a saved one.
    private var savedID: String? {
        if case .saved(let id, _) = editing { id } else { nil }
    }

    /// Where the form asks about models while it's filled in.
    private var asking: ModelAsking {
        switch editing {
        case .newSpace: .newSpace
        case .new(let space), .saved(_, let space): .bots(in: space)
        }
    }

    private var cancelHref: String {
        switch editing {
        case .newSpace: "/"
        case .new(let space): "/spaces/\(space.rawValue.uuidString)"
        case .saved(let id, let space): "/spaces/\(space.rawValue.uuidString)/bots/\(id)"
        }
    }

    var body: some HTML {
        form(.method(.post), .action(action), .class("config-form")) {
            if case .saved(let id, _) = editing { input(.type(.hidden), .name("id"), .value(id)) }
            if case .newSpace(let name) = editing {
                section(.class("config-group")) {
                    h3 { "Space" }
                    label(.class("form-field")) {
                        span(.class("field-label")) { "Name" }
                        input(
                            .type(.text), .name("spaceName"), .value(name), .placeholder("Family, Work, …"),
                            .required)
                    }
                }
            }
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
                // The provider, how it's reached, then its model, and how much it's given.
                ProviderPicker(provider: draft.provider, profileID: savedID, asking: asking)
                ProviderConfigurationFields(
                    provider: draft.provider, settings: draft.settings, profileID: savedID, asking: asking,
                    part: .reaching)
                ModelPicker(modelID: draft.modelID, profileID: savedID, asking: asking)
                ProviderConfigurationFields(
                    provider: draft.provider, settings: draft.settings, profileID: savedID, asking: asking,
                    part: .tuning)
            }
            AgentBehaviorFields(instructions: draft.instructions)
            div(.class("form-actions")) {
                button(.type(.submit), .class("button button-accent")) { submitLabel }
                a(.href(cancelHref), .class("button button-secondary")) { "Cancel" }
            }
        }
    }
}

/// What the bot is told.
struct AgentBehaviorFields: HTML, Sendable {
    let instructions: String

    var body: some HTML {
        section(.class("config-group")) {
            h3 { "Behavior" }
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
