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

struct ModelPicker: HTML, Sendable {
    let catalog: TurgaiModelCatalog
    let selectedModel: AgentModel?

    private static let providerFieldID = "turgai-model-provider"
    private static let modelFieldID = "turgai-model-id"
    private static let noticeID = "turgai-model-notice"

    private var selectedProviderIndex: Int {
        guard let selectedProvider else { return 0 }
        return catalog.providers.firstIndex { $0.provider == selectedProvider } ?? 0
    }

    private var selectedProvider: ModelProviderID? {
        if let provider = selectedModel?.provider {
            return ModelProviderID(rawValue: provider.rawValue)
        }
        if catalog.providers.contains(where: { $0.provider == .ollama }) { return .ollama }
        return catalog.providers.first?.provider
    }

    private func suggestionListID(for index: Int) -> String {
        "turgai-model-suggestions-\(index)"
    }

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Provider" }
            select(
                .name("provider"),
                .id(Self.providerFieldID),
                .required,
                .init(
                    name: "onchange",
                    value:
                        "document.getElementById('\(Self.modelFieldID)').setAttribute('list', this.options[this.selectedIndex].dataset.modelList); document.getElementById('\(Self.noticeID)').textContent = this.options[this.selectedIndex].dataset.modelNotice"
                )
            ) {
                for (index, provider) in catalog.providers.enumerated() {
                    let notice =
                        catalog.notice(for: provider.provider)
                        ?? "Enter a model ID manually if the provider has no discovery service."
                    if provider.provider == selectedProvider {
                        option(
                            .value(provider.id),
                            .selected,
                            .init(name: "data-model-list", value: suggestionListID(for: index)),
                            .init(name: "data-model-notice", value: notice)
                        ) { provider.name }
                    } else {
                        option(
                            .value(provider.id),
                            .init(name: "data-model-list", value: suggestionListID(for: index)),
                            .init(name: "data-model-notice", value: notice)
                        ) { provider.name }
                    }
                }
            }
            p(.class("hint")) { "Suggestions are scoped to the selected provider." }
        }
        label(.class("form-field")) {
            span(.class("field-label")) { "Model ID" }
            input(
                .type(.text),
                .name("modelID"),
                .id(Self.modelFieldID),
                .value(selectedModel?.id.rawValue ?? ""),
                .init(name: "list", value: suggestionListID(for: selectedProviderIndex)),
                .placeholder("Enter a model ID"),
                .required
            )
            for (index, provider) in catalog.providers.enumerated() {
                datalist(.id(suggestionListID(for: index))) {
                    for choice in catalog.choices(for: provider.provider) {
                        option(
                            .value(choice.identifier),
                            .init(
                                name: "label",
                                value: "\(provider.name) · \(choice.displayName)"
                            )
                        )
                    }
                }
            }
            p(.class("hint"), .id(Self.noticeID)) {
                catalog.notice(for: selectedProvider ?? .ollama)
                    ?? "Enter a model ID manually if the provider has no discovery service."
            }
        }
    }
}
