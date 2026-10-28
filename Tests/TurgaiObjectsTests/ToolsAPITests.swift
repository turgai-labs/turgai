import DiscoverableActors
import DistributedCluster
import EventSourcing
import Foundation
import ScopedEffect
import Testing
import TurgaiDomain

@testable import TurgaiObjects

/// What an echo is given.
@Describable
struct Words: Codable {
    var text: String
}

/// What an echo gives back: the words' bytes, and whom it echoed for.
@Describable
struct Echoed: Codable {
    var bytes: Data
    var heard: String
}

/// Object code calls the node's tools as its Swift says: run on the node, on behalf of whoever the
/// call is for, with the values their types are.
@Suite(.serialized)
struct ToolsAPITests {
    private let family = GroupID(rawValue: "family")
    private var ann: CallScope { CallScope(UserID("ann"), in: family, as: .member, allowed: []) }

    /// A tool that gives back the bytes of what it's given, and whom it was called for.
    private let echo = ToolsAPI(tools: [
        ToolsAPI.Tool(
            name: "Echo", description: "Gives back what it's given.",
            functions: [
                ToolsAPI.Function(
                    name: "say", description: "Gives back the words' bytes.", input: Words.jsonSchema,
                    output: Echoed.jsonSchema
                ) { input, _ in
                    // It runs in the chain of the call its code is handling.
                    let words = try JSONDecoder().decode(Words.self, from: try JSONEncoder().encode(input))
                    let heard = CallChain.current?.scope.person.rawValue ?? "no one"
                    let echoed = Echoed(bytes: Data(words.text.utf8), heard: heard)
                    return try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(echoed))
                }
            ])
    ])

    private let parrot = """
        actor Parrot {
            func repeatBack(text: String) async throws -> String {
                let echoed = try await Tools.Echo.say(Words(text: text))
                return "\\(echoed.bytes.count) bytes, for \\(echoed.heard)"
            }
        }
        """

    @Test(.timeLimit(.minutes(1)))
    func codeCallsANodesToolForWhoeverTheCallIsFor() async throws {
        let api = echo
        let uses = Uses(interface: Uses.interface(of: [], tools: api.tools), objects: [:])
        try await withClusterSystem(
            "tools", store: MemoryEventStore(), hostsVirtualActors: true,
            installing: { $0.plugins.install(plugin: ToolsAPIPlugin(api)) }
        ) { node in
            let objects = try await DynamicObjects.resolve(on: node)
            let ann = self.ann
            try await CallChain.$current.withValue(.start(ann)) {
                let id = try await objects.create(
                    name: "Parrot", spec: .new(try Script(code: parrot, type: "Parrot", uses: uses)))
                let reply = try await objects.held(id).respond("repeatBack", arguments: ["text": "héllo"]).reply
                #expect(reply == .string("6 bytes, for ann"))
            }
        }
    }

    /// A web the scope doesn't allow: each get is refused, as the node's authority refuses it,
    /// saying exactly what was refused.
    private let refusing = ToolsAPI(tools: [
        ToolsAPI.Tool(
            name: "Web", description: "Gets what's at a URL.",
            functions: [
                ToolsAPI.Function(
                    name: "get", description: "Gets what's at a URL.", input: Words.jsonSchema,
                    output: Echoed.jsonSchema
                ) { _, _ in
                    throw EffectDenied(effect: "network", refusal: ToolsAPITests.forecast.refusal)
                }
            ])
    ])

    private static let forecast = ExactRequest.http(method: "GET", url: "https://example.com/forecast", body: Data())

    private func reader(_ api: ToolsAPI, _ body: (ClusterSystem, DynamicObject) async throws -> Void) async throws {
        let uses = Uses(interface: Uses.interface(of: [], tools: api.tools), objects: [:])
        let code = """
            actor Reader {
                func read() async throws -> Int {
                    _ = try await Tools.Web.get(Words(text: "forecast"))
                    return 1
                }

                func watch() {
                    Task { _ = try await Tools.Web.get(Words(text: "forecast")) }
                }
            }
            """
        try await withClusterSystem(
            "tools", store: MemoryEventStore(), hostsVirtualActors: true,
            installing: { $0.plugins.install(plugin: ToolsAPIPlugin(api)) }
        ) { node in
            let objects = try await DynamicObjects.resolve(on: node)
            let id = try await CallChain.$current.withValue(.start(ann)) {
                try await objects.create(name: "Reader", spec: .new(try Script(code: code, type: "Reader", uses: uses)))
            }
            try await body(node, try await objects.held(id))
        }
    }

    /// What its scope didn't allow comes back to its caller as that refusal, and the code isn't
    /// failing for it.
    @Test(.timeLimit(.minutes(1)))
    func aRefusalComesBackAsItselfAndIsntTheCodeFailing() async throws {
        try await reader(refusing) { _, reader in
            let ann = self.ann
            do {
                _ = try await CallChain.$current.withValue(.start(ann)) {
                    try await reader.respond("read", arguments: [:])
                }
                Issue.record("a refused get read anyway")
            } catch let refused as EffectDenied {
                #expect(ExactRequest(refusal: refused.refusal) == Self.forecast)
            }
            #expect(try await CallChain.$current.withValue(.start(ann)) { try await reader.health } == .working)
        }
    }

    /// An object's own task is opened by the object, as its maker: what it needed, it asks its
    /// maker's group for.
    @Test(.timeLimit(.minutes(1)))
    func anObjectsOwnTaskAsksItsMakersGroup() async throws {
        try await reader(refusing) { node, reader in
            let ann = self.ann
            _ = try await CallChain.$current.withValue(.start(ann)) {
                try await reader.respond("watch", arguments: [:])
            }
            let group = try await Group.resolve(on: node, id: family)
            var waiting: [AccessRequest] = []
            for _ in 0..<100 where waiting.isEmpty {
                waiting = try await group.waiting()
                if waiting.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
            }
            #expect(waiting.map(\.request) == [Self.forecast])
            #expect(waiting.map(\.by) == [ann.person])
        }
    }

    /// A function no tool has isn't Swift the code can be written with.
    @Test func aFunctionNoToolHasIsntCode() async throws {
        let uses = Uses(interface: Uses.interface(of: [], tools: echo.tools), objects: [:])
        let shouting = parrot.replacingOccurrences(of: "Tools.Echo.say", with: "Tools.Echo.shout")
        #expect(!(await ScriptInstance.problems(in: try Script(code: shouting, type: "Parrot", uses: uses))).isEmpty)
        #expect(await ScriptInstance.problems(in: try Script(code: parrot, type: "Parrot", uses: uses)).isEmpty)
    }
}
