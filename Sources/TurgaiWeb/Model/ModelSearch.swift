import AnyLanguageModel
import Hail
import TurgaiApplication

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
