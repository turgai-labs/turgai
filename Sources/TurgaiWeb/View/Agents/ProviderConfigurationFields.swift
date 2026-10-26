import Elementary
import Hail
import TurgaiApplication
import TurgaiHail

/// Each provider's own settings. Only the selected provider's fieldset is enabled,
/// so the fields it shares with others, such as `apiKey`, submit only its values.
struct ProviderConfigurationFields: HTML, Sendable {
    /// The provider chosen, whose settings `settings` are.
    let provider: AgentModelProvider
    let settings: ProviderSettingsDraft

    private var selectedProvider: AgentModelProvider { provider }

    /// The chosen provider's draft; another's starts empty.
    private func draft(for provider: AgentModelProvider) -> ProviderSettingsDraft? {
        provider == self.provider ? settings : nil
    }

    /// The typed endpoint when this provider is the chosen one.
    private func endpointURL(for provider: AgentModelProvider) -> String? {
        draft(for: provider)?.endpointURL
    }

    private var api: OpenAICompatibleAPI {
        OpenAICompatibleAPI(rawValue: settings.compatibleAPI) ?? .chatCompletions
    }

    private var modelPath: String? { draft(for: .llamaCPP)?.modelPath }

    private var gpuLayers: Int32? { draft(for: .llamaCPP).flatMap { Int32($0.gpuLayers) } }

    private func hasCredential(for provider: AgentModelProvider) -> Bool {
        settings.savedKeyProvider == provider
    }

    /// The typed limit when this provider is the chosen one.
    private func requestLimit(for provider: AgentModelProvider) -> Int? {
        draft(for: provider).flatMap { Int($0.requestLimit) }
    }

    /// The typed window when this provider is the chosen one, otherwise the default.
    private func contextWindow(for provider: AgentModelProvider) -> Int {
        draft(for: provider).flatMap { Int($0.contextWindow) } ?? TurgaiAgentProfileStore.defaultContextWindow
    }

    private func section<Content: HTML>(
        _ provider: AgentModelProvider,
        @HTMLBuilder content: () -> Content
    ) -> ProviderSection<Content> {
        ProviderSection(provider: provider, isSelected: provider == selectedProvider, content: content())
    }

    var body: some HTML {
        div(.class("provider-settings")) {
            section(.ollama) {
                OllamaFields(
                    endpoint: endpointURL(for: .ollama) ?? OllamaConfiguration.defaultBaseURL.absoluteString,
                    window: contextWindow(for: .ollama), limit: requestLimit(for: .ollama))
            }
            for provider in [AgentModelProvider.openAI, .anthropic, .gemini] {
                section(provider) {
                    KeyedProviderFields(
                        hasSavedKey: hasCredential(for: provider), window: contextWindow(for: provider),
                        limit: requestLimit(for: provider))
                }
            }
            section(.openAICompatible) {
                CompatibleProviderFields(
                    endpoint: endpointURL(for: .openAICompatible) ?? "", api: api,
                    hasSavedKey: hasCredential(for: .openAICompatible),
                    window: contextWindow(for: .openAICompatible), limit: requestLimit(for: .openAICompatible))
            }
            section(.system) { SystemModelFields() }
            section(.llamaCPP) {
                LlamaFields(
                    modelPath: modelPath ?? "", gpuLayers: gpuLayers ?? -1, window: contextWindow(for: .llamaCPP))
            }
        }
    }
}

/// A local Ollama server.
private struct OllamaFields: HTML, Sendable {
    let endpoint: String
    let window: Int
    let limit: Int?

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Ollama server URL" }
            input(
                .type(.url), .name("endpointURL"), .value(endpoint),
                .placeholder(OllamaConfiguration.defaultBaseURL.absoluteString))
        }
        ContextWindowField(tokens: window)
        RequestLimitField(limit: limit)
    }
}

/// A hosted provider reached with an API key.
private struct KeyedProviderFields: HTML, Sendable {
    let hasSavedKey: Bool
    let window: Int
    let limit: Int?

    var body: some HTML {
        APIKeyField(hasSavedKey: hasSavedKey)
        ContextWindowField(tokens: window)
        RequestLimitField(limit: limit)
    }
}

/// A server speaking OpenAI's API, at its own address.
private struct CompatibleProviderFields: HTML, Sendable {
    let endpoint: String
    let api: OpenAICompatibleAPI
    let hasSavedKey: Bool
    let window: Int
    let limit: Int?

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Endpoint URL" }
            input(.type(.url), .name("endpointURL"), .value(endpoint))
        }
        label(.class("form-field")) {
            span(.class("field-label")) { "API" }
            select(.name("compatibleAPI")) {
                if api == .chatCompletions {
                    option(.value("chatCompletions"), .selected) { "Chat Completions" }
                    option(.value("responses")) { "Responses" }
                } else {
                    option(.value("chatCompletions")) { "Chat Completions" }
                    option(.value("responses"), .selected) { "Responses" }
                }
            }
        }
        label(.class("form-field")) {
            span(.class("field-label")) { "API key" }
            input(
                .type(.password), .name("apiKey"), .autocomplete(.off),
                .placeholder(hasSavedKey ? "Leave blank to keep the saved key" : "Optional API key"))
        }
        ContextWindowField(tokens: window)
        RequestLimitField(limit: limit)
    }
}

/// The on-device model, whose window is its own.
private struct SystemModelFields: HTML, Sendable {
    var body: some HTML {
        div(.class("form-field")) {
            span(.class("field-label")) { "Context window" }
            p { "\(AgentProviderConfiguration.appleSystemContextWindow.formatted()) tokens" }
            p(.class("hint")) { "Set by the on-device model; it can change with macOS updates." }
        }
    }
}

/// A GGUF model run by llama.cpp.
private struct LlamaFields: HTML, Sendable {
    let modelPath: String
    let gpuLayers: Int32
    let window: Int

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "GGUF model path" }
            input(.type(.text), .name("modelPath"), .value(modelPath), .placeholder("/path/to/model.gguf"))
        }
        label(.class("form-field")) {
            span(.class("field-label")) { "GPU layers" }
            input(.type(.number), .name("gpuLayers"), .value(String(gpuLayers)))
            p(.class("hint")) { "Use -1 to let llama.cpp choose automatically." }
        }
        ContextWindowField(tokens: window)
    }
}

/// One provider's settings, enabled only while that provider is selected.
private struct ProviderSection<Content: HTML>: HTML {
    let provider: AgentModelProvider
    let isSelected: Bool
    let content: Content

    var body: some HTML {
        fieldset(attributes: attributes) { content }
    }

    private var attributes: [HTMLAttribute<HTMLTag.fieldset>] {
        let tag = HTMLAttribute<HTMLTag.fieldset>(name: "data-provider-settings", value: provider.rawValue)
        return isSelected ? [tag, .init(name: "data-active", value: "true")] : [tag, .hidden, .disabled]
    }
}

private struct APIKeyField: HTML {
    let hasSavedKey: Bool

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "API key" }
            input(
                .type(.password), .name("apiKey"), .autocomplete(.off),
                .placeholder(hasSavedKey ? "Leave blank to keep the saved key" : "Paste API key")
            )
        }
        p(.class("hint")) { "The key is stored as a secret and never shown again." }
    }
}

/// How many requests the provider account takes at once: every bot on the same account shares it.
private struct RequestLimitField: HTML {
    let limit: Int?

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Requests at once" }
            input(
                .type(.number), .name("requestLimit"),
                .init(name: "min", value: "1"),
                .value(limit.map(String.init) ?? ""),
                .placeholder("No limit")
            )
            p(.class("hint")) {
                "How many requests this provider account takes at the same time, as its plan allows. Every bot on the same account shares it; the rest wait their turn. Leave empty for no limit."
            }
        }
    }
}

private struct ContextWindowField: HTML {
    let tokens: Int

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Context window" }
            input(
                .type(.number), .name("contextWindow"), .required,
                .init(name: "min", value: "1"),
                .value(String(tokens))
            )
            p(.class("hint")) { "Tokens the model accepts in one prompt, as the provider documents it." }
        }
    }
}
