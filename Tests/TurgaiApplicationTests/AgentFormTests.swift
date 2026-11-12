import Elementary
import Foundation
import Hail
import Testing
import TurgaiApplication
import TurgaiHail

@testable import TurgaiWeb

@Suite("The agent form")
struct AgentFormTests {
    private let server = try! ServerAddress("http://models.test:8080")
    private let profile: TurgaiAgentProfile

    init() throws {
        profile = try TurgaiAgentProfile(
            id: "helper",
            name: "Helper",
            providerConfiguration: .server(
                ModelServer(
                    software: .openAICompatible(.responses), address: server, key: .new(),
                    context: .providers(.said(try ContextWindow(tokens: 32_768))))),
            modelID: AgentModelID(rawValue: "qwen3"),
            reasoningEffort: .low,
            persona: "Calm.",
            instructions: "Answer briefly."
        )
    }

    private func render(_ draft: AgentDraft) -> String {
        AgentConfigurationForm(
            action: "/agents/update", editing: .saved(id: profile.id), draft: draft, submitLabel: "Save changes"
        ).render()
    }

    @Test("a saved agent shows as it's saved")
    func savedAgentShows() {
        let html = render(AgentDraft(profile, requestLimit: 3))

        #expect(html.contains(#"<option value="openai-compatible" selected>"#))
        #expect(html.contains(#"value="qwen3""#))
        #expect(html.contains(#"value="http://models.test:8080""#))
        #expect(html.contains(#"<option value="responses" selected>"#))
        #expect(html.contains(#"<option value="low" selected>"#))
        // A compatible server runs its model with its own window: shown, not typed.
        #expect(!html.contains(#"value="32768""#))
        #expect(html.contains("Set by the provider"))
        #expect(html.contains(#"value="3""#))
        #expect(html.contains("Calm."))
        #expect(html.contains("Leave blank to keep the saved key"))
    }

    @Test("a failed save shows what was typed, but never the key")
    func submittedAgentShowsAgain() {
        let saved = AgentDraft(profile, requestLimit: nil)
        let form: [String: [String]] = [
            "name": ["Helper 2"], "provider": ["openai-compatible"], "modelID": ["qwen3-large"],
            "reasoningEffort": [""], "address": ["not a url"], "compatibleAPI": ["chatCompletions"],
            "contextWindow": ["0"], "apiKey": ["sk-secret"], "persona": [""], "instructions": ["Answer at length."],
        ]
        let draft = AgentDraft(form: form, over: saved)
        let html = render(draft)

        #expect(draft.settings.apiKey == "sk-secret")
        #expect(html.contains(#"value="Helper 2""#))
        #expect(html.contains(#"value="qwen3-large""#))
        #expect(html.contains(#"value="not a url""#))
        #expect(html.contains(#"<option value="" selected>"#))
        #expect(html.contains("Answer at length."))
        #expect(!html.contains("sk-secret"))
    }

    @Test("what's read from the form: a server's address, and the window only when one is typed")
    func whatsRead() throws {
        let saved = AgentDraft(profile, requestLimit: nil)
        let local = try OnboardingInput.submission(
            from: AgentDraft(form: ["provider": ["ollama"], "address": [""], "contextWindow": [""]], over: saved),
            saved: nil)
        #expect(local.location == .server(.ollama, .localOllama))
        #expect(local.contextWindow == nil)
        #expect(local.model == AgentModelID(rawValue: "qwen3"))

        #expect(throws: FormValidationError.invalidValue("server address")) {
            try OnboardingInput.submission(from: AgentDraft(form: ["address": ["not a url"]], over: saved), saved: nil)
        }
        #expect(throws: FormValidationError.invalidValue("context window")) {
            try OnboardingInput.submission(from: AgentDraft(form: ["contextWindow": ["0"]], over: saved), saved: nil)
        }
    }

    /// A key typed is a new one; none keeps the saved one, but only for the same cloud or server,
    /// never another's.
    @Test("a saved key is kept only where it's for")
    func aSavedKeyIsKeptOnlyWhereItsFor() throws {
        let saved = profile.providerConfiguration
        let reference = try #require(saved.credentialReference)
        let sameServer = ModelLocation.server(
            .openAICompatible(.chatCompletions), try ServerAddress("http://models.test:8080/"))

        #expect(ModelSubmission.Key(typed: "new", at: sameServer, saved: saved) == .typed("new"))
        #expect(ModelSubmission.Key(typed: "", at: sameServer, saved: saved) == .kept(reference))
        #expect(
            ModelSubmission.Key(typed: "", at: .server(.ollama, try ServerAddress("http://other.test")), saved: saved)
                == ModelSubmission.Key.none)
        #expect(ModelSubmission.Key(typed: "", at: .cloud(.openAI), saved: saved) == ModelSubmission.Key.none)

        let openAI = AgentProviderConfiguration.cloud(
            CloudAccount(provider: .openAI, key: reference, window: .unsaid))
        #expect(ModelSubmission.Key(typed: "", at: .cloud(.openAI), saved: openAI) == .kept(reference))
        #expect(ModelSubmission.Key(typed: "", at: .cloud(.anthropic), saved: openAI) == ModelSubmission.Key.none)
    }
}
