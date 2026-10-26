import Elementary
import Foundation
import Hail
import Testing
import TurgaiApplication
import TurgaiHail

@testable import TurgaiWeb

@Suite("The agent form")
struct AgentFormTests {
    private let profile = TurgaiAgentProfile(
        id: "helper",
        name: "Helper",
        model: try! AgentModel("openai-compatible/qwen3"),
        reasoningEffort: .low,
        providerConfiguration: .openAICompatible(
            baseURL: URL(string: "http://models.test:8080")!, credential: .new(), api: .responses,
            contextWindow: 32_768),
        persona: "Calm.",
        instructions: "Answer briefly."
    )

    private func render(_ draft: AgentDraft) async -> String {
        let catalog = await TurgaiModelCatalogLoader.load(profiles: [profile], discovery: TurgaiModelCatalogLoader.Discovery(ollama: { _ in [] }))
        return AgentConfigurationForm(
            action: "/agents/update", editing: .saved(id: profile.id), draft: draft, modelCatalog: catalog,
            submitLabel: "Save changes"
        ).render()
    }

    @Test("a saved agent shows as it's saved")
    func savedAgentShows() async {
        let html = await render(AgentDraft(profile, requestLimit: 3))

        #expect(html.contains(#"value="qwen3""#))
        #expect(html.contains(#"value="http://models.test:8080""#))
        #expect(html.contains(#"<option value="responses" selected>"#))
        #expect(html.contains(#"<option value="low" selected>"#))
        #expect(html.contains(#"value="32768""#))
        #expect(html.contains(#"value="3""#))
        #expect(html.contains("Calm."))
        #expect(html.contains("Leave blank to keep the saved key"))
    }

    @Test("a failed save shows what was typed, but never the key")
    func submittedAgentShowsAgain() async {
        let saved = AgentDraft(profile, requestLimit: nil)
        let form: [String: [String]] = [
            "name": ["Helper 2"], "provider": ["openai-compatible"], "modelID": ["qwen3-large"],
            "reasoningEffort": [""], "endpointURL": ["not a url"], "compatibleAPI": ["chatCompletions"],
            "contextWindow": ["0"], "apiKey": ["sk-secret"], "persona": [""], "instructions": ["Answer at length."],
        ]
        let draft = AgentDraft(form: form, over: saved)
        let html = await render(draft)

        #expect(draft.settings.apiKey == "sk-secret")
        #expect(html.contains(#"value="Helper 2""#))
        #expect(html.contains(#"value="qwen3-large""#))
        #expect(html.contains(#"value="not a url""#))
        #expect(html.contains(#"<option value="" selected>"#))
        #expect(html.contains("Answer at length."))
        #expect(!html.contains("sk-secret"))
    }
}
