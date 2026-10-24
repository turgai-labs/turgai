import DiscoverableActors
import DistributedCluster
import Foundation
import Testing
import TurgaiObjects

@testable import TurgaiApplication

/// Methods of one name are overloads, as in Swift: each its own action, by its selector, and a
/// call is to the one it names, or whose labels its arguments are given by.
@Suite
struct OverloadTests {
    static let code = """
        actor Planner {
            var latest = ""

            func plan(request: String) -> String {
                latest = "request: " + request
                return latest
            }

            func plan(_ request: String) -> String {
                latest = "unlabelled: " + request
                return latest
            }

            func plan(context: String) -> String {
                latest = "context: " + context
                return latest
            }

            func reset() {
                latest = ""
            }
        }
        """

    @Test(.timeLimit(.minutes(1)))
    func eachOverloadIsItsOwnAction() async throws {
        try await withClusterSystem("dynamic", store: MemoryEventStore(), hostsVirtualActors: true) { node in
            let objects = try await DynamicObjects.resolve(on: node, scope: .shared)
            let identity = try await objects.create(
                name: "Planner", spec: .new(try Script(code: Self.code, type: "Planner")))
            let planner = try await objects.held(identity)

            // Described each by its selector; a name only one method has, by its name.
            let actions = try await planner.describe().actions.keys.sorted()
            #expect(actions == ["plan(_:)", "plan(context:)", "plan(request:)", "reset"])

            // As a model calls each, by its action and its parameters' names.
            #expect(try await planner.respond("plan(context:)", arguments: ["context": "tea"]).reply == "context: tea")
            #expect(try await planner.respond("plan(request:)", arguments: ["request": "tea"]).reply == "request: tea")
            #expect(try await planner.respond("plan(_:)", arguments: ["request": "tea"]).reply == "unlabelled: tea")

            // As code calls it, by its name and labels.
            #expect(try await planner.respond("plan", arguments: ["_0": "tea"]).reply == "unlabelled: tea")
            #expect(try await planner.respond("plan", arguments: ["context": "tea"]).reply == "context: tea")
            #expect(try await planner.respond("plan", arguments: ["request": "tea"]).reply == "request: tea")

            // What no overload takes says which there are.
            let refused = await #expect(throws: (any Error).self) {
                _ = try await planner.respond("plan", arguments: ["topic": "tea"])
            }
            #expect("\(refused.map { String(describing: $0) } ?? "")".contains("plan(context: String)"))
        }
    }

    @Test func eachOverloadsToolHasANameProvidersTake() {
        #expect(ActionKeys.toolName(of: "plan(request:)") == "plan_request")
        #expect(ActionKeys.toolName(of: "plan(_:)") == "plan")
        #expect(ActionKeys.toolName(of: "plan(_: String)") == "plan_String")
        #expect(ActionKeys.toolName(of: "plan(from:to:)") == "plan_from_to")
        #expect(ActionKeys.toolName(of: "reset") == "reset")
        #expect(ActionKeys.baseName(of: "plan(request:)") == "plan")
    }
}
