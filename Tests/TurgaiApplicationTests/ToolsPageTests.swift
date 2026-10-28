import Foundation
import Testing

@testable import TurgaiWeb

@Suite("Tools page")
struct ToolsPageTests {
    @Test("stage numbering ignores the hidden template row")
    func stageNumberingIgnoresTemplate() {
        #expect(
            TurgaiToolEditorPage.editorScript.contains(
                "[data-stage-row]:not([data-builder-template])"
            )
        )
        #expect(TurgaiToolEditorPage.editorScript.contains("data-add-after"))
        #expect(TurgaiToolEditorPage.editorScript.contains("stage.after(cloned.row)"))
        #expect(TurgaiToolEditorPage.editorScript.contains("builder-row-entering"))
        #expect(TurgaiToolEditorPage.editorScript.contains("builder-row-removing"))
        #expect(TurgaiToolEditorPage.editorScript.contains("updateStageNumbers()"))
    }

    @Test("a blank template row is not saved as a workflow step")
    func blankTemplateRowIsIgnoredOnSave() throws {
        let draft = TurgaiToolDraft(
            form: [
                "toolName": ["weather"],
                "toolDescription": ["Gets the weather."],
                "bodyKind": ["workflow"],
                "stageID": ["lookup", "explain", ""],
                "stageKind": ["fetch", "think", "fetch"],
                "stageURL": ["https://example.com/weather", "", ""],
                "stageInstruction": ["", "Explain the result.", ""],
            ],
            fileName: "weather.tool.json",
            kind: .new
        )

        let definition = try draft.encodedDefinition()
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(definition.utf8)) as? [String: Any]
        )
        let body = try #require(object["body"] as? [String: Any])
        let steps = try #require(body["steps"] as? [[String: Any]])

        #expect(steps.count == 2)
        #expect(steps.map { $0["id"] as? String } == ["lookup", "explain"])
    }
}
