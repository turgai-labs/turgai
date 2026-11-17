import AnyLanguageModel
import DiscoverableActors
import DistributedCluster
import Foundation
import Hail
import Testing
import TurgaiSpaces

@testable import TurgaiApplication
@testable import TurgaiObjects

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
                objects: try await Space.identified(by: AsAPerson.person.space, on: node).objects(
                    for: AsAPerson.person.person), actorSystem: node,
                writer: ObjectWriter(endpoint: WritesCode(code: "actor Coffee {\n    var cups = 0\n}")))
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

/// A model that writes the same code, whatever it's asked.
private struct WritesCode: ModelEndpoint {
    let code: String
    let model = "test/writer"
    let effectiveContextWindow: Int? = 16_384
    var tokenCounting: TokenCounting { .unavailable }

    func stream<Input, Output>(
        request: ModelRequest<Input>,
        tools: [AnyTool],
        authority: any Authority,
        generating: Output.Type,
        purpose: ModelRequestPurpose
    ) -> AsyncStream<ModelEvent<Output>>
    where Input: Sendable, Output: Codable & Sendable & Generable, Output.PartiallyGenerated: Sendable {
        let code = self.code
        return AsyncStream { continuation in
            continuation.yield(.generated(try! Output(GeneratedContent(code))))
            continuation.finish()
        }
    }
}
