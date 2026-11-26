import ComposableArchitecture
import Foundation
import TurgaiModels

/// A bot as it's written: what it's called and told, and what thinks for it, the models of the
/// provider chosen asked for as it's chosen. A new space's first bot, a bot added to a space, or one
/// of its bots changed.
@Reducer
package struct BotForm {
    package init() {}

    /// What the chosen provider offers, asked as the bot's model is chosen.
    package enum Models: Equatable {
        case notAsked
        case asking
        case found([String])
        case unavailable(String)
    }

    /// A saved bot being changed: where its key is kept, which is asked with when none is typed.
    package struct Saved: Equatable {
        package let space: SpaceID
        package let bot: BotID
        /// Whether it has a key, kept when none is typed.
        package let hasKey: Bool
    }

    @ObservableState
    package struct State: Equatable {
        /// Who writes it.
        package let session: Session
        /// The bot it changes, when it changes one.
        package var saved: Saved?
        package var name = ""
        package var instructions = ""
        package var provider = ModelProvider.ollama
        package var address = ""
        package var apiKey = ""
        package var model = ""
        /// The window typed: empty is the model's own.
        package var contextWindow = ""
        package var models = Models.notAsked

        /// A new bot.
        package init(session: Session, name: String = "") {
            self.session = session
            self.name = name
        }

        /// `bot`, one of `space`'s, as it's saved: to change.
        package init(session: Session, changing bot: SpaceBot, in space: SpaceID) {
            self.session = session
            saved = Saved(space: space, bot: bot.id, hasKey: bot.hasKey)
            name = bot.name
            instructions = bot.instructions
            provider = bot.provider
            address = bot.address ?? ""
            model = bot.model
            contextWindow = bot.contextWindow.map(String.init) ?? ""
        }

        package var canSave: Bool {
            !trimmed(name).isEmpty && !trimmed(model).isEmpty
                && (contextWindow.isEmpty || Int(contextWindow).map { $0 > 0 } == true)
        }
        /// A server's address, for a provider whose models run on one.
        package var asksAddress: Bool { provider.kind == .server }
        /// What an empty address means.
        package var addressPrompt: String { provider == .ollama ? "Ollama on this Mac" : "http://…" }
        /// A key, for a provider that may ask for one.
        package var asksKey: Bool { provider.kind != .local }
        /// What an empty key means.
        package var keyPrompt: String { saved?.hasKey == true ? "Keep the saved key" : "" }
        /// A window, which is yours to choose on a server of your own.
        package var asksWindow: Bool { provider.kind == .server }
        /// The models the provider was found to offer, to pick from.
        package var suggestedModels: [String] { if case .found(let models) = models { models } else { [] } }
        /// What asking the provider says, while it's asked or when it couldn't be.
        package var modelsNote: String? {
            switch models {
            case .asking: "Asking the provider for its models…"
            case .unavailable(let why): why
            case .notAsked, .found: nil
            }
        }

        /// The provider asked for its models with what's chosen so far: with the saved bot's key
        /// when none is typed.
        package var modelsRequest: ModelsRequest {
            ModelsRequest(
                provider: provider, address: written(address), apiKey: written(apiKey), botID: saved?.bot,
                spaceID: saved?.space)
        }

        /// The bot, as it's written: its saved key kept when none is typed.
        package var configuration: BotConfiguration {
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

    package enum Action: BindableAction {
        case binding(BindingAction<State>)
        /// Shown: the provider is asked for its models, unless it was.
        case shown
        case modelsAnswered(ModelsAnswer)
    }

    private enum CancelID { case models }

    @Dependency(\.server) package var server
    @Dependency(\.continuousClock) package var clock

    package var body: some ReducerOf<Self> {
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
