import ComposableArchitecture
import Foundation
import SwiftUI
import TurgaiModels

/// A bot's fields: what it's called and told, where its model runs, and which.
package struct BotFields: View {
    @Bindable package var store: StoreOf<BotForm>

    package var body: some View {
        Form {
            TextField("Name", text: $store.name)
            TextField("Instructions", text: $store.instructions, axis: .vertical).lineLimit(3...6)
            Picker("Runs on", selection: $store.provider) {
                ForEach(ModelProvider.allCases, id: \.self) { provider in Text(provider.title).tag(provider) }
            }
            if store.asksAddress {
                TextField("Address", text: $store.address, prompt: Text(store.addressPrompt)).typedVerbatim()
            }
            if store.asksKey {
                SecureField("API key", text: $store.apiKey, prompt: Text(store.keyPrompt))
            }
            ModelField(model: $store.model, suggested: store.suggestedModels)
            if let note = store.modelsNote {
                Text(note).font(.callout).foregroundStyle(Color.turgaiMuted)
            }
            if store.asksWindow {
                TextField("Window", text: $store.contextWindow, prompt: Text("The model's own")).typedVerbatim()
            }
        }
        .columnsFormStyle()
        .task { store.send(.shown) }
    }
}

/// Which model, written, with the ones the provider offers to pick from: as the field's suggestions
/// on a Mac, in a menu beside it on a phone, whose fields take none.
private struct ModelField: View {
    @Binding var model: String
    let suggested: [String]

    var body: some View {
        #if os(macOS)
            TextField("Model", text: $model).typedVerbatim()
                .textInputSuggestions {
                    ForEach(suggested, id: \.self) { model in Text(model).textInputCompletion(model) }
                }
        #else
            HStack {
                TextField("Model", text: $model).typedVerbatim()
                if !suggested.isEmpty {
                    Menu {
                        ForEach(suggested, id: \.self) { choice in Button(choice) { model = choice } }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .accessibilityLabel("Models")
                }
            }
        #endif
    }
}

extension ModelProvider {
    /// What the bot form calls it.
    package var title: String {
        switch self {
        case .appleSystem: "Apple on this Mac"
        case .ollama: "Ollama"
        case .openAICompatible: "A server that speaks OpenAI's API"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        }
    }
}
