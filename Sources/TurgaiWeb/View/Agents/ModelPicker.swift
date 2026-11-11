import Elementary
import ElementaryHTMX
import Hail
import TurgaiApplication

/// The provider to choose, by where its models run: choosing one shows its settings, and asks it
/// for its models.
struct ProviderPicker: HTML, Sendable {
    /// The provider chosen.
    let provider: AgentProvider
    /// The saved bot whose key asking may use.
    let profileID: String?

    private static let showSettings =
        "document.querySelectorAll('[data-provider-settings]').forEach((panel) => panel.disabled = panel.hidden = panel.dataset.providerSettings !== this.value)"

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Provider" }
            // Its settings show before it's asked: only the shown ones are sent.
            select(
                attributes: [.name("provider"), .required, .init(name: "onchange", value: Self.showSettings)]
                    + ModelSearchRequest.attributes(on: "change", profileID: profileID)
            ) {
                for kind in AgentProvider.Kind.allCases {
                    let providers = AgentProvider.offered.filter { $0.kind == kind }
                    if !providers.isEmpty {
                        optgroup(.init(name: "label", value: kind.title)) {
                            for each in providers {
                                if each == provider {
                                    option(.value(each.name), .selected) { each.title }
                                } else {
                                    option(.value(each.name)) { each.title }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The model to use, the chosen provider's models suggested once it's asked for them.
struct ModelPicker: HTML, Sendable {
    /// The model ID as typed.
    let modelID: String
    /// The saved bot whose key asking may use.
    let profileID: String?

    static let suggestionsID = "turgai-model-suggestions"

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Model" }
            input(
                .type(.text), .name("modelID"), .value(modelID),
                .init(name: "list", value: Self.suggestionsID),
                .placeholder("Its ID, as the provider names it"),
                .required
            )
            datalist(.id(Self.suggestionsID)) {}
            // Asked as the page opens: the saved provider's models, with its saved key.
            p(
                attributes: [
                    .class("hint model-search"), .id(ModelSearchRequest.statusID),
                    .init(name: "aria-live", value: "polite"),
                ] + ModelSearchRequest.attributes(on: "load", profileID: profileID)
            ) {
                span(.class("model-search-finding")) { "Finding models…" }
                span(.class("model-search-answer"), .id(ModelSearchRequest.answerID)) {}
            }
        }
    }
}

/// What asks the chosen provider for its models, as the form has it: the answer goes under the
/// model field, and its models into the field's suggestions.
enum ModelSearchRequest {
    static let statusID = "turgai-model-search"
    static let answerID = "turgai-model-search-answer"
    /// A moment after a field is typed in.
    static let typing = "input changed delay:600ms"

    static func attributes<Tag: HTMLTrait.Attributes.Global>(on trigger: String, profileID: String?)
        -> [HTMLAttribute<Tag>]
    {
        [
            .hx.post("/agents/models"),
            .hx.trigger(HTMLAttributeValue.HTMX.EventTrigger(rawValue: trigger)),
            .hx.include("closest form"),
            .hx.target("#\(answerID)"),
            .hx.indicator("#\(statusID)"),
        ] + (profileID.map { [.hx.vals(#"{"id": "\#($0)"}"#)] } ?? [])
    }
}

/// What asking the chosen provider for its models found, under the model field; and, in place of
/// the field's suggestions, its models, or none.
struct ModelSearchAnswer: HTML, Sendable {
    let outcome: ModelSearch.Outcome

    var body: some HTML {
        switch outcome {
        case .found(let models):
            span { models.count == 1 ? "Found 1 model." : "Found \(models.count) models." }
        case .invalid(let field):
            span { "Enter a valid \(field) to see its models." }
        case .unavailable(let reason) where reason.kind == .keyNeeded:
            span { "Enter the API key to see its models." }
        case .unavailable(let reason):
            span(.class("model-search-error")) { reason.sentence }
        }
        datalist(.id(ModelPicker.suggestionsID), .hx.swapOOB(.outerHTML)) {
            for model in models { option(.value(model.rawValue)) }
        }
    }

    private var models: [AgentModelID] {
        if case .found(let models) = outcome { models } else { [] }
    }
}
