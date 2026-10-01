import Elementary
import Hail
import TurgaiApplication
import TurgaiHail

/// Each provider's own settings. Only the selected provider's fieldset is enabled,
/// so the fields it shares with others, such as `apiKey`, submit only its values.
struct ProviderConfigurationFields: HTML, Sendable {
    let profile: TurgaiAgentProfile?

    private var selectedProvider: AgentModelProvider {
        profile?.model.provider ?? .ollama
    }

    private var endpointURL: String? {
        guard let configuration = profile?.providerConfiguration else { return nil }
        switch configuration {
        case .ollama(let url, _), .openAICompatible(let url, _, _, _): return url.absoluteString
        default: return nil
        }
    }

    private var api: OpenAICompatibleAPI {
        guard let configuration = profile?.providerConfiguration,
            case .openAICompatible(_, _, let api, _) = configuration
        else { return .chatCompletions }
        return api
    }

    private var modelPath: String? {
        guard let configuration = profile?.providerConfiguration,
            case .llamaCPP(let llama, _) = configuration
        else { return nil }
        return llama.modelPath
    }

    private var gpuLayers: Int32? {
        guard let configuration = profile?.providerConfiguration,
            case .llamaCPP(let llama, _) = configuration
        else { return nil }
        return llama.gpuLayers
    }

    private func hasCredential(for provider: AgentModelProvider) -> Bool {
        guard let configuration = profile?.providerConfiguration else { return false }
        switch (provider, configuration) {
        case (.openAI, .openAI), (.anthropic, .anthropic), (.gemini, .gemini), (.openAICompatible, .openAICompatible):
            return true
        default:
            return false
        }
    }

    /// The saved window when this provider is the saved one, otherwise the default.
    private func contextWindow(for provider: AgentModelProvider) -> Int {
        guard let profile, profile.model.provider == provider else {
            return TurgaiAgentProfileStore.defaultContextWindow
        }
        return profile.contextWindow
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
                label(.class("form-field")) {
                    span(.class("field-label")) { "Ollama server URL" }
                    input(
                        .type(.url), .name("endpointURL"),
                        .value(endpointURL ?? OllamaConfiguration.defaultBaseURL.absoluteString),
                        .placeholder(OllamaConfiguration.defaultBaseURL.absoluteString)
                    )
                }
                ContextWindowField(tokens: contextWindow(for: .ollama))
            }
            section(.openAI) {
                APIKeyField(hasSavedKey: hasCredential(for: .openAI))
                ContextWindowField(tokens: contextWindow(for: .openAI))
            }
            section(.anthropic) {
                APIKeyField(hasSavedKey: hasCredential(for: .anthropic))
                ContextWindowField(tokens: contextWindow(for: .anthropic))
            }
            section(.gemini) {
                APIKeyField(hasSavedKey: hasCredential(for: .gemini))
                ContextWindowField(tokens: contextWindow(for: .gemini))
            }
            section(.openAICompatible) {
                label(.class("form-field")) {
                    span(.class("field-label")) { "Endpoint URL" }
                    input(.type(.url), .name("endpointURL"), .value(endpointURL ?? ""))
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
                        .placeholder(
                            hasCredential(for: .openAICompatible)
                                ? "Leave blank to keep the saved key" : "Optional API key"
                        )
                    )
                }
                ContextWindowField(tokens: contextWindow(for: .openAICompatible))
            }
            section(.system) {
                div(.class("form-field")) {
                    span(.class("field-label")) { "Context window" }
                    p { "\(AgentProviderConfiguration.appleSystemContextWindow.formatted()) tokens" }
                    p(.class("hint")) { "Set by the on-device model; it can change with macOS updates." }
                }
            }
            section(.llamaCPP) {
                label(.class("form-field")) {
                    span(.class("field-label")) { "GGUF model path" }
                    input(
                        .type(.text), .name("modelPath"), .value(modelPath ?? ""), .placeholder("/path/to/model.gguf"))
                }
                label(.class("form-field")) {
                    span(.class("field-label")) { "GPU layers" }
                    input(.type(.number), .name("gpuLayers"), .value(String(gpuLayers ?? -1)))
                    p(.class("hint")) { "Use -1 to let llama.cpp choose automatically." }
                }
                ContextWindowField(tokens: contextWindow(for: .llamaCPP))
            }
        }
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
