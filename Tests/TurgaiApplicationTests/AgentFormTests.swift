import Elementary
import Foundation
import Hail
import Testing
import TurgaiAgents
import TurgaiApplication
import TurgaiDomain
import TurgaiHail

@testable import TurgaiWeb

@Suite("The bot form")
struct AgentFormTests {
    private let server = try! ServerAddress("http://models.test:8080")
    private let bot: Bot

    init() throws {
        bot = Bot(
            name: BotName("Helper")!, instructions: "Answer briefly.",
            model: BotModel(
                location: .server(
                    ModelServer(
                        software: .openAICompatible(.responses), address: server, key: .new(),
                        context: .providers(.said(try ContextWindow(tokens: 32_768))))),
                name: ModelName("qwen3")!))
    }

    private let family = SpaceID()

    private func render(_ draft: AgentDraft) -> String {
        AgentConfigurationForm(
            action: "/spaces/\(family.rawValue.uuidString)/bots/update",
            editing: .saved(id: bot.id.description, in: family), draft: draft,
            submitLabel: "Save changes"
        ).render()
    }

    @Test("a saved agent shows as it's saved")
    func savedAgentShows() {
        let html = render(AgentDraft(bot, requestLimit: 3))

        #expect(html.contains(#"<option value="openai-compatible" selected>"#))
        #expect(html.contains(#"value="qwen3""#))
        #expect(html.contains(#"value="http://models.test:8080""#))
        #expect(html.contains(#"<option value="responses" selected>"#))
        // A compatible server runs its model with its own window: shown, not typed.
        #expect(!html.contains(#"value="32768""#))
        #expect(html.contains("Set by the provider"))
        #expect(html.contains(#"value="3""#))
        #expect(html.contains("Answer briefly."))
        #expect(html.contains("Leave blank to keep the saved key"))
    }

    @Test("a failed save shows what was typed, but never the key")
    func submittedAgentShowsAgain() {
        let saved = AgentDraft(bot, requestLimit: nil)
        let form: [String: [String]] = [
            "name": ["Helper 2"], "provider": ["openai-compatible"], "modelID": ["qwen3-large"],
            "address": ["not a url"], "compatibleAPI": ["chatCompletions"],
            "contextWindow": ["0"], "apiKey": ["sk-secret"], "instructions": ["Answer at length."],
        ]
        let draft = AgentDraft(form: form, over: saved)
        let html = render(draft)

        #expect(draft.settings.apiKey == "sk-secret")
        #expect(html.contains(#"value="Helper 2""#))
        #expect(html.contains(#"value="qwen3-large""#))
        #expect(html.contains(#"value="not a url""#))
        #expect(html.contains("Answer at length."))
        #expect(!html.contains("sk-secret"))
    }

    @Test("what's read from the form: a server's address, and the window only when one is typed")
    func whatsRead() throws {
        let saved = AgentDraft(bot, requestLimit: nil)
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
        let saved = bot.model.location
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
