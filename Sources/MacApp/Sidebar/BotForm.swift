import ComposableArchitecture
import Foundation
import SwiftUI
import TurgaiModels

/// A bot as it's written: what it's called and told, and what thinks for it, the models of the
/// provider chosen asked for as it's chosen. A new space's first bot, a bot added to a space, or one
/// of its bots changed.
@Reducer
struct BotForm {
    /// What the chosen provider offers, asked as the bot's model is chosen.
    enum Models: Equatable {
        case notAsked
        case asking
        case found([String])
        case unavailable(String)
    }

    /// A saved bot being changed: where its key is kept, which is asked with when none is typed.
    struct Saved: Equatable {
        let space: SpaceID
        let bot: BotID
        /// Whether it has a key, kept when none is typed.
        let hasKey: Bool
    }

    @ObservableState
    struct State: Equatable {
        /// Who writes it.
        let session: Session
        /// The bot it changes, when it changes one.
        var saved: Saved?
        var name = ""
        var instructions = ""
        var provider = ModelProvider.ollama
        var address = ""
        var apiKey = ""
        var model = ""
        /// The window typed: empty is the model's own.
        var contextWindow = ""
        var models = Models.notAsked

        /// A new bot.
        init(session: Session, name: String = "") {
            self.session = session
            self.name = name
        }

        /// `bot`, one of `space`'s, as it's saved: to change.
        init(session: Session, changing bot: SpaceBot, in space: SpaceID) {
            self.session = session
            saved = Saved(space: space, bot: bot.id, hasKey: bot.hasKey)
            name = bot.name
            instructions = bot.instructions
            provider = bot.provider
            address = bot.address ?? ""
            model = bot.model
            contextWindow = bot.contextWindow.map(String.init) ?? ""
        }

        var canSave: Bool {
            !trimmed(name).isEmpty && !trimmed(model).isEmpty
                && (contextWindow.isEmpty || Int(contextWindow).map { $0 > 0 } == true)
        }
        /// A server's address, for a provider whose models run on one.
        var asksAddress: Bool { provider.kind == .server }
        /// What an empty address means.
        var addressPrompt: String { provider == .ollama ? "Ollama on this Mac" : "http://…" }
        /// A key, for a provider that may ask for one.
        var asksKey: Bool { provider.kind != .local }
        /// What an empty key means.
        var keyPrompt: String { saved?.hasKey == true ? "Keep the saved key" : "" }
        /// A window, which is yours to choose on a server of your own.
        var asksWindow: Bool { provider.kind == .server }
        /// The models the provider was found to offer, to pick from.
        var suggestedModels: [String] { if case .found(let models) = models { models } else { [] } }
        /// What asking the provider says, while it's asked or when it couldn't be.
        var modelsNote: String? {
            switch models {
            case .asking: "Asking the provider for its models…"
            case .unavailable(let why): why
            case .notAsked, .found: nil
            }
        }

        /// The provider asked for its models with what's chosen so far: with the saved bot's key
        /// when none is typed.
        var modelsRequest: ModelsRequest {
            ModelsRequest(
                provider: provider, address: written(address), apiKey: written(apiKey), botID: saved?.bot,
                spaceID: saved?.space)
        }

        /// The bot, as it's written: its saved key kept when none is typed.
        var configuration: BotConfiguration {
            BotConfiguration(
                name: trimmed(name), instructions: trimmed(instructions),
                model: ModelChoice(
                    provider: provider, address: asksAddress ? written(address) : nil,
                    apiKey: asksKey ? written(apiKey) : nil, model: trimmed(model),
                    contextWindow: asksWindow ? Int(contextWindow) : nil))
        }

        private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        private func written(_ text: String) -> String? { trimmed(text).isEmpty ? nil : trimmed(text) }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        /// Shown: the provider is asked for its models, unless it was.
        case shown
        case modelsAnswered(ModelsAnswer)
    }

    private enum CancelID { case models }

    @Dependency(\.server) var server
    @Dependency(\.continuousClock) var clock

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.provider), .binding(\.address), .binding(\.apiKey):
                return askModels(&state, after: .milliseconds(400))

            case .binding:
                return .none

            case .shown:
                return state.models == .notAsked ? askModels(&state, after: .zero) : .none

            case .modelsAnswered(let answer):
                switch answer {
                case .found(let models): state.models = .found(models)
                case .unavailable(let why): state.models = .unavailable(why)
                }
                return .none
            }
        }
    }

    /// The provider asked for its models, once what's chosen has settled for `wait`: an ask still
    /// waiting gives way to this one.
    private func askModels(_ state: inout State, after wait: Duration) -> Effect<Action> {
        state.models = .asking
        return .run { [session = state.session, asked = state.modelsRequest] send in
            try await clock.sleep(for: wait)
            do {
                await send(.modelsAnswered(try await server.models(session, asked)))
            } catch {
                await send(.modelsAnswered(.unavailable("Couldn't ask the provider for its models.")))
            }
        }
        .cancellable(id: CancelID.models, cancelInFlight: true)
    }
}

/// A bot's fields: what it's called and told, where its model runs, and which.
struct BotFields: View {
    @Bindable var store: StoreOf<BotForm>

    var body: some View {
        Form {
            TextField("Name", text: $store.name)
            TextField("Instructions", text: $store.instructions, axis: .vertical).lineLimit(3...6)
            Picker("Runs on", selection: $store.provider) {
                ForEach(ModelProvider.allCases, id: \.self) { provider in Text(provider.title).tag(provider) }
            }
            if store.asksAddress {
                TextField("Address", text: $store.address, prompt: Text(store.addressPrompt))
            }
            if store.asksKey {
                SecureField("API key", text: $store.apiKey, prompt: Text(store.keyPrompt))
            }
            TextField("Model", text: $store.model)
                .textInputSuggestions {
                    ForEach(store.suggestedModels, id: \.self) { model in Text(model).textInputCompletion(model) }
                }
            if let note = store.modelsNote {
                Text(note).font(.callout).foregroundStyle(Color.turgaiMuted)
            }
            if store.asksWindow {
                TextField("Window", text: $store.contextWindow, prompt: Text("The model's own"))
            }
        }
        .formStyle(.columns)
        .task { store.send(.shown) }
    }
}

extension ModelProvider {
    /// What the bot form calls it.
    var title: String {
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
