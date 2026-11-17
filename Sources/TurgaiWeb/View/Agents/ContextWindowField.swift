import Elementary
import ElementaryHTMX4
import Hail
import TurgaiAgents
import TurgaiApplication
import TurgaiDomain

/// A provider's context window. Where your own server or this machine runs the model, how many
/// tokens it gets is yours to type; where a provider runs it, the window is the provider's own,
/// shown once a model is chosen. Choosing a model sends this field again, in place of the one shown.
struct ContextWindowField: HTML, Sendable {
    let provider: AgentProvider
    /// The window as typed.
    let tokens: String
    let model: ModelWindow.Outcome
    /// Whether it's sent alone, in place of the one shown.
    var replacing = false

    static func id(for provider: AgentProvider) -> String { "turgai-context-window-\(provider.name)" }

    var body: some HTML {
        switch shown {
        case .typed(let placeholder, let hint):
            label(attributes: [.class("form-field"), .id(Self.id(for: provider))] + swap()) {
                span(.class("field-label")) { "Context window" }
                input(
                    .type(.number), .name("contextWindow"),
                    .init(name: "min", value: "1"),
                    .value(tokens),
                    .placeholder(placeholder)
                )
                p(.class("hint")) { hint }
            }
        case .providers(let value, let hint):
            div(attributes: [.class("form-field"), .id(Self.id(for: provider))] + swap()) {
                span(.class("field-label")) { "Context window" }
                p { value }
                p(.class("hint")) { hint }
            }
        }
    }

    /// In place of the one shown, when it's sent alone.
    private func swap<Tag: HTMLTrait.Attributes.Global>() -> [HTMLAttribute<Tag>] {
        replacing ? [.hx.swapOOB(.outerHTML)] : []
    }

    /// What it shows: a field to type in, or the provider's window.
    private enum Shown {
        case typed(placeholder: String, hint: String)
        case providers(String, hint: String)
    }

    private var shown: Shown {
        switch model {
        case .chosen(let model, let takes?, let empty?) where empty.tokens < takes:
            .typed(
                placeholder: "The model's own",
                hint:
                    "\(model.rawValue) takes up to \(takes.formatted()) tokens. Leave empty to give it \(empty.tokens.formatted()) of them: Ollama keeps memory for the whole window."
            )
        case .chosen(let model, let takes?, _):
            .typed(
                placeholder: "The model's own",
                hint: "\(model.rawValue) takes up to \(takes.formatted()) tokens. Leave empty to give it all of them.")
        case .chosen(let model, nil, _):
            .typed(
                placeholder: "Tokens",
                hint: "How many tokens \(model.rawValue) takes isn't known here: enter how many it gets.")
        case .providers(let model, .said(let window)?):
            .providers("\(window.tokens.formatted()) tokens", hint: "Set by the provider for \(model.rawValue).")
        case .providers(let model, .unsaid?):
            .providers(
                "Not said",
                hint:
                    "The provider doesn't say \(model.rawValue)'s window: the conversation is shortened when the provider refuses a request as too long."
            )
        case .providers(let model, nil):
            .providers(
                "Set by the provider",
                hint: "Shown once the provider can be asked about \(model.rawValue).")
        case .none:
            switch provider.kind {
            case .local:
                .typed(placeholder: "Tokens", hint: "How many tokens the model gets, as its card says it takes.")
            case .server where provider == .ollama:
                .typed(
                    placeholder: "The model's own",
                    hint:
                        "How many tokens your own Ollama server gives the model. Leave empty for as many as it takes, up to \(ContextWindow.standard.tokens.formatted()), as Ollama keeps memory for the whole window. Ollama's cloud runs its models with their own."
                )
            case .server, .cloud:
                .providers(
                    "Set by the provider",
                    hint: "The provider runs the model with its own window, shown once it's chosen.")
            }
        }
    }
}
