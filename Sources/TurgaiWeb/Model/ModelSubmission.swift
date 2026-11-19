import AnyLanguageModel
import Hail
import TurgaiAgents
import TurgaiApplication
import TurgaiDomain

/// A bot's model as its form gives it, read but not yet checked: where it runs, the model, the key
/// it's reached with, and the window typed, when one is.
struct ModelSubmission: Sendable {
    /// The key a provider is asked with.
    enum Key: Sendable, Equatable {
        case none
        /// The saved one, kept.
        case kept(AgentCredentialReference)
        /// One typed now.
        case typed(String)

        /// The key `typed`, or else the one `saved` keeps when it's for `location` too: never
        /// another provider's or server's.
        init(typed: String, at location: ModelLocation, saved: AgentProviderConfiguration?) {
            if !typed.isEmpty {
                self = .typed(typed)
            } else if let saved, let reference = saved.credentialReference, saved.location.sharesKey(with: location) {
                self = .kept(reference)
            } else {
                self = .none
            }
        }

        /// Its value: a kept one's as `credentials` has it, when it can be read.
        func value(in credentials: AgentCredentialStore) async -> String? {
            switch self {
            case .none: nil
            case .kept(let reference): try? await credentials.value(for: reference)
            case .typed(let value): value
            }
        }
    }

    let location: ModelLocation
    let model: AgentModelID
    let key: Key
    /// None is the model's own.
    let contextWindow: ContextWindow?

    /// The model, checked where it runs with its key, and given its window: what's saved.
    ///
    /// - Throws: ``ModelRefusal``, when the model can't be used there, or the window doesn't fit
    ///   it; `CancellationError`, when it's cancelled.
    func checked(credentials: AgentCredentialStore) async throws -> CheckedModel {
        let details: ModelDetails?
        switch try await location.checkAvailability(of: model, key: await key.value(in: credentials)) {
        case .available(let checked):
            details = checked
        case .unavailable(let reason):
            guard Self.mayComeLater.contains(reason.kind) else { throw ModelRefusal.unavailable(reason) }
            details = nil
        }
        let reference: AgentCredentialReference?
        let newKey: (reference: AgentCredentialReference, value: String)?
        switch key {
        case .none:
            (reference, newKey) = (nil, nil)
        case .kept(let kept):
            (reference, newKey) = (kept, nil)
        case .typed(let value):
            let new = AgentCredentialReference.new()
            (reference, newKey) = (new, (new, value))
        }
        do throws(ModelConfigurationError) {
            let configuration = try location.configuration(
                key: reference, model: model, typed: contextWindow, details: details)
            return CheckedModel(configuration: configuration, model: model, newKey: newKey)
        } catch {
            throw ModelRefusal.configuration(error)
        }
    }

    /// What can't be used now but may be later, so doesn't stop a save: a server that's down, a
    /// model still getting ready, or a provider's own failure.
    private static let mayComeLater: Set<ModelUnavailability.Kind> = [.unreachable, .notReady, .providerError, .other]
}

/// A bot's model, checked where it runs: what's saved.
struct CheckedModel: Sendable {
    let configuration: AgentProviderConfiguration
    let model: AgentModelID
    /// A key typed now, to save under the configuration's reference.
    let newKey: (reference: AgentCredentialReference, value: String)?
}

/// Why a bot's model isn't saved.
enum ModelRefusal: Error {
    /// It can't be used where the form says.
    case unavailable(ModelUnavailability)
    /// Where it runs takes something the form doesn't give: a key, or a window that fits.
    case configuration(ModelConfigurationError)
}

extension ModelUnavailability {
    /// What's wrong, said to the one setting the bot up.
    var sentence: String {
        switch kind {
        case .keyNeeded: "This provider asks for an API key."
        case .keyRefused: "The provider refused this API key."
        case .modelNotFound: "The provider doesn't have this model."
        case .unreachable: "The server couldn't be reached."
        case .deviceNotEligible: "This machine can't run Apple's on-device model."
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in System Settings to use its model."
        case .notReady: "The on-device model isn't ready yet."
        case .providerError: "The provider answered with an error: \(underlyingError.map { "\($0)" } ?? "none given")."
        case .other: "The model can't be used now."
        }
    }
}
