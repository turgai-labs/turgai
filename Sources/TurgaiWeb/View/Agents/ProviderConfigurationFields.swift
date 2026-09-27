import Elementary
import Hail
import TurgaiApplication
import TurgaiHail

struct ProviderConfigurationFields: HTML, Sendable {
    let profile: TurgaiAgentProfile?

    private var selectedProvider: String {
        profile?.model.provider.rawValue ?? "ollama"
    }

    private var endpointURL: String? {
        guard let configuration = profile?.providerConfiguration else { return nil }
        switch configuration {
        case .ollama(let url), .openAICompatible(let url, _, _): return url.absoluteString
        default: return nil
        }
    }

    private var api: OpenAICompatibleAPI {
        guard let configuration = profile?.providerConfiguration,
            case .openAICompatible(_, _, let api) = configuration
        else { return .chatCompletions }
        return api
    }

    private var modelPath: String? {
        guard let configuration = profile?.providerConfiguration,
            case .llamaCPP(let llama) = configuration
        else { return nil }
        return llama.modelPath
    }

    private var gpuLayers: Int32? {
        guard let configuration = profile?.providerConfiguration,
            case .llamaCPP(let llama) = configuration
        else { return nil }
        return llama.gpuLayers
    }

    private func hasCredential(for provider: String) -> Bool {
        guard let configuration = profile?.providerConfiguration else { return false }
        switch (provider, configuration) {
        case ("openai", .openAI), ("anthropic", .anthropic), ("gemini", .gemini):
            return true
        case ("openai-compatible", .openAICompatible):
            return true
        default:
            return false
        }
    }

    var body: some HTML {
        div(.class("provider-settings")) {
            div(
                .init(name: "data-provider-settings", value: "ollama"),
                selectedProvider == "ollama" ? .init(name: "data-active", value: "true") : .hidden
            ) {
                label(.class("form-field")) {
                    span(.class("field-label")) { "Ollama server URL" }
                    input(
                        .type(.url), .name("endpointURL"),
                        .value(endpointURL ?? OllamaConfiguration.defaultBaseURL.absoluteString),
                        .placeholder(OllamaConfiguration.defaultBaseURL.absoluteString)
                    )
                }
            }
            for provider in ["openai", "anthropic", "gemini"] {
                div(
                    .init(name: "data-provider-settings", value: provider),
                    selectedProvider == provider ? .init(name: "data-active", value: "true") : .hidden
                ) {
                    label(.class("form-field")) {
                        span(.class("field-label")) { "API key" }
                        input(
                            .type(.password), .name("apiKey"), .autocomplete(.off),
                            .placeholder(
                                hasCredential(for: provider) ? "Leave blank to keep the saved key" : "Paste API key")
                        )
                    }
                    p(.class("hint")) { "The key is stored as a secret and never shown again." }
                }
            }
            div(
                .init(name: "data-provider-settings", value: "openai-compatible"),
                selectedProvider == "openai-compatible" ? .init(name: "data-active", value: "true") : .hidden
            ) {
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
                            hasCredential(for: "openai-compatible")
                                ? "Leave blank to keep the saved key" : "Optional API key"
                        )
                    )
                }
            }
            div(
                .init(name: "data-provider-settings", value: "llama-cpp"),
                selectedProvider == "llama-cpp" ? .init(name: "data-active", value: "true") : .hidden
            ) {
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
            }
        }
    }
}
