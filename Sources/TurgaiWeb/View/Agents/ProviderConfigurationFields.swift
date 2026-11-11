import Elementary
import ElementaryHTMX
import Hail
import TurgaiApplication

/// Each provider's own settings. Only the selected provider's fieldset is enabled,
/// so the fields it shares with others, such as `apiKey`, submit only its values.
struct ProviderConfigurationFields: HTML, Sendable {
    /// The provider chosen, whose settings `settings` are.
    let provider: AgentProvider
    let settings: ProviderSettingsDraft
    /// The saved bot these are the settings of, when they're a saved one's: its models are asked
    /// for with its saved key, when the key isn't typed again.
    let profileID: String?
    let part: Part

    /// Which of a provider's settings these are: how it's reached, before the model is chosen;
    /// or how much it's given, after.
    enum Part: Sendable {
        case reaching
        case tuning
    }

    /// The chosen provider's draft; another's starts empty.
    private func draft(for provider: AgentProvider) -> ProviderSettingsDraft? {
        provider == self.provider ? settings : nil
    }

    private func section<Content: HTML>(
        _ provider: AgentProvider,
        @HTMLBuilder content: () -> Content
    ) -> ProviderSection<Content> {
        ProviderSection(provider: provider, isSelected: provider == self.provider, content: content())
    }

    var body: some HTML {
        div(.class("provider-settings")) {
            switch part {
            case .reaching: reaching
            case .tuning: tuning
            }
        }
    }

    /// Where each provider is, and its key: typing either asks it for its models again.
    @HTMLBuilder private var reaching: some HTML {
        #if Llama
            section(.llamaCPP) {
                LlamaFields(
                    modelFile: draft(for: .llamaCPP)?.modelFile ?? "",
                    gpuLayers: draft(for: .llamaCPP)?.gpuLayers ?? "-1")
            }
        #endif
        section(.ollama) {
            AddressField(
                address: draft(for: .ollama)?.address ?? "", placeholder: ServerAddress.localOllama.description,
                hint: "Leave empty for Ollama on this machine; Ollama's cloud is at \(ServerAddress.ollamaCloud).",
                profileID: profileID)
            APIKeyField(
                hasSavedKey: settings.savedKeyProvider == .ollama, placeholder: "Only for Ollama's cloud",
                profileID: profileID)
        }
        section(.openAICompatible) {
            AddressField(
                address: draft(for: .openAICompatible)?.address ?? "", placeholder: "",
                hint: "The address its API is under, such as its /v1.", profileID: profileID)
            CompatibleAPIField(
                api: draft(for: .openAICompatible).flatMap { OpenAICompatibleAPI(rawValue: $0.compatibleAPI) }
                    ?? .chatCompletions)
            APIKeyField(
                hasSavedKey: settings.savedKeyProvider == .openAICompatible,
                placeholder: "Only when the server asks for one", profileID: profileID)
        }
        for cloud in [AgentProvider.openAI, .anthropic, .gemini] {
            section(cloud) {
                APIKeyField(
                    hasSavedKey: settings.savedKeyProvider == cloud, placeholder: "Paste API key", profileID: profileID)
            }
        }
    }

    /// How much each provider is given: its context window, and an account's requests at once.
    @HTMLBuilder private var tuning: some HTML {
        section(.appleSystem) { SystemModelFields() }
        #if Llama
            section(.llamaCPP) {
                ContextWindowField(tokens: draft(for: .llamaCPP)?.contextWindow ?? "", hint: .file)
            }
        #endif
        for provider in AgentProvider.offered where provider.kind != .local {
            section(provider) {
                ContextWindowField(
                    tokens: draft(for: provider)?.contextWindow ?? "",
                    hint: provider == .ollama ? .ollamaServer : .provider)
                RequestLimitField(limit: draft(for: provider)?.requestLimit ?? "")
            }
        }
    }
}

/// A server's address.
private struct AddressField: HTML, Sendable {
    let address: String
    let placeholder: String
    let hint: String
    let profileID: String?

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Server address" }
            input(
                attributes: [.type(.url), .name("address"), .value(address), .placeholder(placeholder)]
                    + ModelSearchRequest.attributes(on: ModelSearchRequest.typing, profileID: profileID))
            p(.class("hint")) { hint }
        }
    }
}

/// Which of OpenAI's APIs a server speaks.
private struct CompatibleAPIField: HTML, Sendable {
    let api: OpenAICompatibleAPI

    var body: some HTML {
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
    }
}

/// The key a provider is asked with: typing one asks it for its models with it.
private struct APIKeyField: HTML, Sendable {
    let hasSavedKey: Bool
    let placeholder: String
    let profileID: String?

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "API key" }
            input(
                attributes: [
                    .type(.password), .name("apiKey"), .autocomplete(.off),
                    .placeholder(hasSavedKey ? "Leave blank to keep the saved key" : placeholder),
                ] + ModelSearchRequest.attributes(on: ModelSearchRequest.typing, profileID: profileID))
            p(.class("hint")) { "The key is stored as a secret and never shown again." }
        }
    }
}

/// The on-device model, whose window is its own.
private struct SystemModelFields: HTML, Sendable {
    var body: some HTML {
        div(.class("form-field")) {
            span(.class("field-label")) { "Context window" }
            p { "\(LocalModel.appleSystemContextWindow.formatted()) tokens" }
            p(.class("hint")) { "Set by the on-device model; it can change with macOS updates." }
        }
    }
}

#if Llama
    /// A GGUF model run by llama.cpp.
    private struct LlamaFields: HTML, Sendable {
        let modelFile: String
        let gpuLayers: String

        var body: some HTML {
            label(.class("form-field")) {
                span(.class("field-label")) { "GGUF model file" }
                input(.type(.text), .name("modelFile"), .value(modelFile), .placeholder("/path/to/model.gguf"))
            }
            label(.class("form-field")) {
                span(.class("field-label")) { "GPU layers" }
                input(.type(.number), .name("gpuLayers"), .value(gpuLayers))
                p(.class("hint")) { "Use -1 to let llama.cpp choose automatically." }
            }
        }
    }
#endif

/// One provider's settings, enabled only while that provider is selected.
private struct ProviderSection<Content: HTML>: HTML {
    let provider: AgentProvider
    let isSelected: Bool
    let content: Content

    var body: some HTML {
        fieldset(attributes: attributes) { content }
    }

    private var attributes: [HTMLAttribute<HTMLTag.fieldset>] {
        let tag = HTMLAttribute<HTMLTag.fieldset>(name: "data-provider-settings", value: provider.name)
        return isSelected ? [tag, .init(name: "data-active", value: "true")] : [tag, .hidden, .disabled]
    }
}

/// How many requests the provider account takes at once: every bot on the same account shares it.
private struct RequestLimitField: HTML {
    let limit: String

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Requests at once" }
            input(
                .type(.number), .name("requestLimit"),
                .init(name: "min", value: "1"),
                .value(limit),
                .placeholder("No limit")
            )
            p(.class("hint")) {
                "How many requests this provider account takes at the same time, as its plan allows. Every bot on the same account shares it; the rest wait their turn. Leave empty for no limit."
            }
        }
    }
}

/// How many tokens a prompt may use: empty is the model's own, when where it runs says it.
private struct ContextWindowField: HTML {
    let tokens: String
    let hint: Hint

    enum Hint {
        /// A provider says its models' windows.
        case provider
        /// An Ollama server gives a model memory for its whole window.
        case ollamaServer
        #if Llama
            /// A GGUF file's window isn't read.
            case file
        #endif
    }

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Context window" }
            input(
                .type(.number), .name("contextWindow"),
                .init(name: "min", value: "1"),
                .value(tokens),
                .placeholder(placeholder)
            )
            p(.class("hint")) { text }
        }
    }

    private var placeholder: String {
        switch hint {
        case .provider, .ollamaServer: "The model's own"
        #if Llama
            case .file: "Tokens"
        #endif
        }
    }

    private var text: String {
        switch hint {
        case .provider:
            "Tokens the model may use in one prompt. Leave empty for as many as the model takes."
        case .ollamaServer:
            "Tokens the model may use in one prompt. Leave empty for as many as the model takes, up to \(ContextWindow.standard.tokens.formatted()): Ollama keeps memory for the whole window."
        #if Llama
            case .file:
                "Tokens the model may use in one prompt, as its card says."
        #endif
        }
    }
}
