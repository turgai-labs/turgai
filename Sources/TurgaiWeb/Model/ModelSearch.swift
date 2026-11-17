import AnyLanguageModel
import Hail
import TurgaiAgents
import TurgaiApplication
import TurgaiDomain

/// The chosen provider's models, asked for as the form has the provider: with the key typed, or
/// else the one saved for the same cloud or server, never another's.
enum ModelSearch {
    /// What asking found.
    enum Outcome: Sendable {
        case found([AgentModelID])
        /// The form doesn't say where the provider is: this field isn't valid.
        case invalid(field: String)
        case unavailable(ModelUnavailability)
    }

    /// The models of the provider `draft` chooses, the key kept in `saved` asked with when it's
    /// for the same place.
    static func search(
        _ draft: AgentDraft, saved: AgentProviderConfiguration?, credentials: AgentCredentialStore
    ) async -> Outcome {
        let location: ModelLocation
        do throws(FormValidationError) {
            location = try OnboardingInput.location(from: draft)
        } catch {
            guard case .invalidValue(let field) = error else { return .invalid(field: "") }
            return .invalid(field: field)
        }
        let key = ModelSubmission.Key(typed: draft.settings.apiKey, at: location, saved: saved)
        do {
            return .found(try await location.availableModels(key: await key.value(in: credentials)))
        } catch let unavailable as ModelUnavailability {
            return .unavailable(unavailable)
        } catch {
            return .unavailable(ModelUnavailability(kind: .other, underlyingError: error))
        }
    }
}

/// The chosen model's window, asked where it runs as the form has it: how many tokens it takes,
/// and who decides how many it gets.
enum ModelWindow {
    enum Outcome: Sendable {
        /// No model is chosen yet, or the form doesn't say where it runs.
        case none
        /// Your own server or this machine runs it: it gets what you choose. It takes `takes`
        /// tokens, and an empty window gives it `empty`, when those are known.
        case chosen(AgentModelID, takes: Int?, empty: ContextWindow?)
        /// The provider runs it with its own window: said, unsaid, or, when the provider can't be
        /// asked now, nil.
        case providers(AgentModelID, ProviderWindow?)
    }

    /// The window of the model `draft` chooses, asked with the key typed, or else the one `saved`
    /// keeps for the same place.
    static func ask(
        _ draft: AgentDraft, saved: AgentProviderConfiguration?, credentials: AgentCredentialStore
    ) async -> Outcome {
        guard !draft.modelID.isEmpty, let location = try? OnboardingInput.location(from: draft) else { return .none }
        let model = AgentModelID(rawValue: draft.modelID)
        let key = ModelSubmission.Key(typed: draft.settings.apiKey, at: location, saved: saved)
        let availability = try? await location.checkAvailability(of: model, key: await key.value(in: credentials))
        let takes: Int?
        if case .available(let details)? = availability { takes = details.contextSize } else { takes = nil }
        guard location.choosesWindow(for: model) else {
            guard case .available? = availability else { return .providers(model, nil) }
            return .providers(model, ProviderWindow(modelTakes: takes))
        }
        let empty = (try? location.configuration(key: nil, model: model, typed: nil, modelTakes: takes))?.contextWindow
        return .chosen(model, takes: takes, empty: empty.flatMap { try? ContextWindow(tokens: $0) })
    }
}
