import DiscoverableActors
import DistributedCluster
import EventSourcing
import Foundation
import Hail
import Testing
import TurgaiDomain
import TurgaiSpaces
import VirtualActors

@testable import TurgaiApplication
@testable import TurgaiObjects

/// Objects live on the first node, which also hosts the objects made here, as a runtime's does;
/// the model's session runs on the second, so every call goes through a remote reference.
func withObjectNodes(
    _ body: (_ objects: ClusterSystem, _ session: ClusterSystem) async throws -> Void
) async throws {
    let store = MemoryEventStore()
    try await withClusterSystem("objects", store: store, hostsVirtualActors: true) { objects in
        try await withClusterSystem("session", store: store, joining: objects, hostsVirtualActors: false) { session in
            try await body(objects, session)
        }
    }
}

/// The receptionist spreads check-ins by gossip, so wait until the session's node sees them.
func waitForRoots(_ count: Int, in session: ObjectSession) async throws -> DiscoveryJSON {
    for _ in 0..<50 {
        let roots = try await session.list()
        if case .array(let entries) = roots, entries.count >= count { return roots }
        try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("Timed out waiting for \(count) roots")
    return try await session.list()
}

@Suite(.serialized, .asAPerson)
struct ObjectToolsTests {
    /// A YAML mistake is explained, Elm-style: the line, a caret under the spot, why, and the fix.
    @Test
    func yamlMistakesAreExplained() {
        func explanation(_ text: String) -> String {
            do {
                _ = try ObjectSession.parse(text)
                return "parsed"
            } catch {
                return String(describing: error)
            }
        }
        let colon = explanation("actions:\n  - startShift: call the shop (from: self).")
        #expect(colon.contains("I couldn't read line 2:"))
        #expect(colon.contains("has a second \": \" in it"))
        #expect(colon.contains(#"- startShift: "call the shop (from: self).""#))
        #expect(explanation("name: Ann\n\tshop: shop").contains("indented with a tab"))
        #expect(
            explanation("name: Ann\nproperties:\n  pending: {value: []}\n shop: {object: shop}").contains(
                "isn't indented like the lines around it"))
    }

    /// Results are YAML; reading one back gives the same value, even text that looks like
    /// something else.
    @Test
    func resultsAreYAMLThatReadsBackTheSame() throws {
        let value: DiscoveryJSON = [
            "flag": "true", "number": "1", "time": "08:30", "answer": "no", "empty": "",
            "missing": nil, "count": 3, "price": 2.5, "done": false,
            "items": [["title": "Milk", "list": "Groceries"]],
        ]
        let text = try ObjectSession.text(value)
        #expect(!text.contains("{\""))
        #expect(try ObjectSession.parse(text) == value)
    }

    @Test
    func findRanksRootsByTheQuery() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let board = try await Board.start(on: objectsNode)
            // The space's built-in objects, given to the session as a turn's tools give them.
            let boardObject = try DiscoverableObject.resolve(id: board.id, using: sessionNode)
            let boardDescribed = try await boardObject.describe()
            let boardEntry = ObjectEntry(
                id: .virtual(try #require(board.id.virtualActorID)), object: boardObject, type: boardDescribed.type,
                description: boardDescribed.description,
                actions: boardDescribed.actions.map { ObjectCatalog.signature($0.key, input: $0.value.input) }.sorted(),
                events: boardDescribed.events.keys.sorted())

            let session = ObjectSession(
                in: AsAPerson.person.space,
                objects: try await Space.identified(by: AsAPerson.person.space, on: sessionNode).objects(
                    for: AsAPerson.person.person), actorSystem: sessionNode, builtIns: [boardEntry])
            _ = try await waitForRoots(1, in: session)

            func found(_ query: String) async throws -> [String] {
                guard case .array(let entries) = try await session.find(query) else { return [] }
                return entries.compactMap { if case .string(let id)? = $0["object_id"] { id } else { nil } }
            }
            #expect(try await found("show a card") == ["board"])
            #expect(try await found("weather").isEmpty)
            _ = board
        }
    }

    @Test
    func theObjectsPageListsRootsAndTheirHandlesWorkWithoutListing() async throws {
        try await withObjectNodes { objectsNode, sessionNode in
            let board = try await Board.start(on: objectsNode)
            // The space's built-in objects, given to the session as a turn's tools give them.
            let boardObject = try DiscoverableObject.resolve(id: board.id, using: sessionNode)
            let boardDescribed = try await boardObject.describe()
            let boardEntry = ObjectEntry(
                id: .virtual(try #require(board.id.virtualActorID)), object: boardObject, type: boardDescribed.type,
                description: boardDescribed.description,
                actions: boardDescribed.actions.map { ObjectCatalog.signature($0.key, input: $0.value.input) }.sorted(),
                events: boardDescribed.events.keys.sorted())

            // The objects page says what objects are for, lists the roots by handle, and links them
            // directly.
            let listing = ObjectSession(
                in: AsAPerson.person.space,
                objects: try await Space.identified(by: AsAPerson.person.space, on: sessionNode).objects(
                    for: AsAPerson.person.person), actorSystem: sessionNode, builtIns: [boardEntry])
            var lines: [String] = []
            var links: [String] = []
            for _ in 0..<50 {
                let page = try await listing.open(ObjectAddress.objects.address)
                lines = (page.output.textValue ?? "").split(separator: "\n").map(String.init)
                links = page.links.map(\.name)
                if lines.contains(where: { $0.hasPrefix("- id: `board`; type: `Board`") }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(lines.first == ObjectTools.description)
            #expect(lines.contains("Available objects:"))
            #expect(lines.contains { $0.hasPrefix("- id: `board`; type: `Board`") })
            #expect(Set(links).isSuperset(of: ["create_object", "search_objects", "list_objects"]))
            #expect(links.contains("object_board"))
            #expect(!links.contains("use_object"))
            // Its link says what objects are for in a sentence.
            #expect(ObjectTools.link.description == ObjectTools.description)

            // A new session, as a later turn gets: the listed handle works straight away.
            let session = ObjectSession(
                in: AsAPerson.person.space,
                objects: try await Space.identified(by: AsAPerson.person.space, on: sessionNode).objects(
                    for: AsAPerson.person.person), actorSystem: sessionNode, builtIns: [boardEntry])
            #expect(try await session.describe(try await session.id(written: "board"))["type"] == "Board")
            _ = board
        }
    }

    @Test
    func handlesAreRequiredForObjectArguments() async throws {
        await #expect(throws: ObjectToolError.unknownHandle("h9")) {
            try await withObjectNodes { _, sessionNode in
                let session = ObjectSession(
                    in: AsAPerson.person.space,
                    objects: try await Space.identified(by: AsAPerson.person.space, on: sessionNode).objects(
                        for: AsAPerson.person.person), actorSystem: sessionNode)
                _ = try await session.describe(try await session.id(written: "h9"))
            }
        }
    }
}

@Test
func actionSignaturesNameTheirArguments() {
    let add: JSONValue = [
        "type": "object",
        "properties": ["title": ["type": "string"], "notes": ["type": "string"], "due": ["type": "string"]],
        "required": ["title"],
    ]
    #expect(ObjectCatalog.signature("add", input: add) == "add(title: String, due: String?, notes: String?)")
    #expect(
        ObjectCatalog.signature(
            "play", input: ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]])
            == "play(query: String)")
    #expect(ObjectCatalog.signature("pause", input: nil) == "pause()")
}

extension ToolOutput {
    /// Its text, for a text output.
    var textValue: String? {
        if case .text(let text) = self { text } else { nil }
    }
}
