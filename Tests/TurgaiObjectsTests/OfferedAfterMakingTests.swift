import AnyLanguageModel
import DiscoverableActors
import DistributedCluster
import Foundation
import Hail
import Testing
import TurgaiDomain

@testable import TurgaiApplication
@testable import TurgaiObjects
@testable import TurgaiSpaces

/// Making an object offers the root's tools again, with it among the objects they choose from, in
/// the result of making it: the turn that made it can change it, share it and remove it.
@Suite(.asAPerson)
struct OfferedAfterMakingTests {
    @Test(.timeLimit(.minutes(1)))
    func makingAnObjectOffersItAtTheRoot() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("offered", store: store, hostsVirtualActors: true) { node in
            let objects = try await DynamicObjects.of(AsAPerson.person.space, on: node)
            _ = try await objects.create(
                name: "Tea", spec: .new(try Script(code: "actor Tea {\n    var cups = 0\n}", type: "Tea")))
            let session = ObjectSession(
                in: AsAPerson.person.space,
                objects: try await DynamicObjects.of(AsAPerson.person.space, on: node), actorSystem: node)
            let offered = try await ObjectTools(session: session).offered()
            #expect(try Self.choices(of: "edit_object", in: offered) == ["tea"])

            let made = try await withEffect(
                MakeObjectEffect(session: session, objectName: "Coffee", task: "Counts cups of coffee."),
                authority: TurgaiAuthority()
            ) { try await MakeObjectEffect.run(in: $0) }
            for tool in ["edit_object", "share_object", "remove_object"] {
                #expect(try Self.choices(of: tool, in: made.offered) == ["coffee", "tea"], "\(tool)")
            }
            #expect(!made.offered.map(\.name).contains("use_object"))
        }
    }

    /// Making an object lands on its code page: its code now, what its code can use by name, and
    /// tools to show one of those in full and to save code. Code that's wrong isn't saved, and
    /// what's wrong comes back; code that's right is saved, and runs.
    @Test(.timeLimit(.minutes(1)))
    func makingAnObjectOpensItsCodePage() async throws {
        let store = MemoryEventStore()
        try await withClusterSystem("code-page", store: store, hostsVirtualActors: true) { node in
            let objects = try await DynamicObjects.of(AsAPerson.person.space, on: node)
            _ = try await objects.create(
                name: "Tea", spec: .new(try Script(code: "actor Tea {\n    var cups = 0\n}", type: "Tea")))
            let session = ObjectSession(
                in: AsAPerson.person.space,
                objects: try await DynamicObjects.of(AsAPerson.person.space, on: node), actorSystem: node)
            _ = try await withEffect(
                MakeObjectEffect(session: session, objectName: "Coffee", task: "Counts cups of coffee."),
                authority: TurgaiAuthority()
            ) { try await MakeObjectEffect.run(in: $0) }

            let page = try await session.open(ToolPageAddress(rawValue: "code:coffee"))
            let text = page.output.textRepresentation
            #expect(text.contains("actor Coffee {}"))
            #expect(text.contains("- `Tea`"))
            #expect(page.links.map(\.name) == ["open_declaration", "save_code"])

            let open = try #require(page.links.first { $0.name == "open_declaration" } as? OpenDeclarationTool)
            let tea = try await open.runOutput(
                input: GeneratedContent(properties: ["name": "Tea"]), authority: TurgaiAuthority())
            #expect(tea.result.textRepresentation.contains("Tea(id:"))

            let save = try #require(page.links.first { $0.name == "save_code" } as? SaveCodeTool)
            await #expect(throws: ObjectToolError.self) {
                _ = try await save.runOutput(
                    input: SaveCodeTool.Input(code: "actor Coffee {\n    var cups = nothing\n}"),
                    authority: TurgaiAuthority())
            }
            #expect(
                try await session.open(ToolPageAddress(rawValue: "code:coffee")).output.textRepresentation.contains(
                    "actor Coffee {}"))
            let saved = try await save.runOutput(
                input: SaveCodeTool.Input(code: "actor Coffee {\n    var cups = 0\n}"), authority: TurgaiAuthority())
            #expect(saved.result.textRepresentation.hasPrefix("Saved coffee"))
        }
    }

    /// The objects the tool `name` among `tools` chooses from, as its schema offers them.
    private static func choices(of name: String, in tools: [any HailCore.Tool]) throws -> [String] {
        guard let tool = tools.first(where: { $0.name == name }) else { return [] }
        typealias Value = DiscoverableActors.JSONValue
        var schema = try JSONDecoder().decode(Value.self, from: try JSONEncoder().encode(tool.schema.parameters))
        // Written as a reference to its one definition.
        if case .string(let reference)? = schema["$ref"],
            let defined = schema["$defs"]?[String(reference.dropFirst("#/$defs/".count))]
        {
            schema = defined
        }
        let object: Value? = schema["properties"]?["object"]
        if let listed: [Value] = object?["enum"]?.arrayValue {
            return listed.compactMap { (value: Value) -> String? in value.stringValue }.sorted()
        }
        let options: [Value] = object?["anyOf"]?.arrayValue ?? []
        return options.compactMap { (option: Value) -> String? in option["const"]?.stringValue }.sorted()
    }
}
