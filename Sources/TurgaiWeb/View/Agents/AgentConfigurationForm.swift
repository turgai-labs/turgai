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

struct AgentConfigurationForm: HTML, Sendable {
    let action: String
    let profile: TurgaiAgentProfile?
    let modelCatalog: TurgaiModelCatalog
    let submitLabel: String

    private var selectedModel: AgentModel? { profile?.model }

    private var chatIDs: String {
        profile?.telegramChatIDs.map(String.init).joined(separator: ", ") ?? ""
    }

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
                    span(.class("field-label")) { "Ollama address" }
                    input(
                        .type(.url), .name("ollamaBaseURL"),
                        .value(profile?.ollamaBaseURL?.absoluteString ?? ""),
                        .placeholder(OllamaConfiguration.defaultBaseURL.absoluteString)
                    )
                    p(.class("hint")) { "Used when this bot uses an Ollama model." }
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
                h3 { "Telegram" }
                label(.class("form-field")) {
                    span(.class("field-label")) { "Telegram chats" }
                    input(
                        .type(.text), .name("telegramChatIDs"), .value(chatIDs),
                        .placeholder("Optional chat IDs, separated by commas")
                    )
                    p(.class("hint")) { "Leave empty for the default route." }
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
