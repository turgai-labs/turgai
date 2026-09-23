import AnyLanguageModel
import Foundation
import Synchronization
import Testing
import TurgaiApplication

#if canImport(FoundationEssentials)
    import FoundationEssentials
#endif

private final class LoadCapture: Sendable {
    let issues: Mutex<[UserToolLoadIssue]>

    init() {
        issues = Mutex([])
    }

    var report: @Sendable (UserToolLoadIssue) -> Void {
        { [self] issue in
            self.issues.withLock { $0.append(issue) }
        }
    }
}

private func makeRegistry(
    directory: URL,
    capture: LoadCapture = LoadCapture()
) -> UserToolRegistry {
    UserToolRegistry(directory: directory, report: capture.report)
}

private func writeSpec(
    _ contents: String,
    named name: String,
    in directory: URL
) throws {
    try contents.write(
        to: directory.appendingPathComponent(name),
        atomically: true,
        encoding: .utf8
    )
}

@Suite("User tool registry")
struct UserToolRegistryTests {
    @Test("a valid wasm spec loads with wasm approval defaulting to always")
    func validWasmSpec() throws {
        let directory = try makeTemporaryDirectory()
        try writeSpec(
            """
            {
              "name": "house_status",
              "description": "Checks the smart-home hub.",
              "arguments": {
                "type": "object",
                "properties": {
                  "base_url": {"type": "string"}
                },
                "required": ["base_url"]
              },
              "body": {"kind": "wasm", "module": "house.wasm"}
            }
            """,
            named: "house.json",
            in: directory
        )
        let capture = LoadCapture()
        let tools = makeRegistry(directory: directory, capture: capture).load()

        #expect(tools.count == 1)
        let tool = try #require(tools.first)
        #expect(tool.name == "house_status")
        #expect(tool.approval == .always)
        guard case .wasm(let wasm) = tool.body else {
            Issue.record("Expected a wasm body")
            return
        }
        #expect(wasm.module.lastPathComponent == "house.wasm")
        #expect(wasm.module.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(tool.argumentNames == ["base_url"])
        capture.issues.withLock { #expect($0.isEmpty) }
    }

    @Test("a native process spec loads with process approval defaulting to always")
    func validProcessSpec() throws {
        let directory = try makeTemporaryDirectory()
        try writeSpec(
            """
            {
              "name": "swift_tool",
              "description": "Runs a locally built Swift program.",
              "arguments": {
                "type": "object",
                "properties": {
                  "value": {"type": "string"}
                }
              },
              "body": {
                "kind": "process",
                "argv": [".build/debug/SwiftTool", "--value", "{{value}}"],
                "environment": {"TOOL_VALUE": "{{value}}"}
              }
            }
            """,
            named: "swift.json",
            in: directory
        )
        let capture = LoadCapture()
        let tools = makeRegistry(directory: directory, capture: capture).load()

        let tool = try #require(tools.first)
        #expect(tool.approval == .always)
        guard case .process(let process) = tool.body else {
            Issue.record("Expected a process body")
            return
        }
        #expect(process.argv == [".build/debug/SwiftTool", "--value", "{{value}}"])
        #expect(process.environment == ["TOOL_VALUE": "{{value}}"])
        capture.issues.withLock { #expect($0.isEmpty) }
    }

    @Test("an absent arguments block means a no-argument tool")
    func noArgumentsSpec() throws {
        let directory = try makeTemporaryDirectory()
        try writeSpec(
            """
            {
              "name": "disk_free",
              "description": "Shows free disk space.",
              "body": {"kind": "wasm", "module": "disk.wasm"}
            }
            """,
            named: "disk.json",
            in: directory
        )
        let capture = LoadCapture()
        let tools = makeRegistry(directory: directory, capture: capture).load()
        #expect(tools.count == 1)
        #expect(tools.first?.argumentNames == [])
        capture.issues.withLock { #expect($0.isEmpty) }
    }

    @Test("a prompt spec defaults to never asking approval")
    func promptSpecDefaultApproval() throws {
        let directory = try makeTemporaryDirectory()
        try writeSpec(
            """
            {
              "name": "summarize",
              "description": "Summarizes text.",
              "arguments": {
                "type": "object",
                "properties": {
                  "text": {"type": "string"}
                },
                "required": ["text"]
              },
              "body": {"kind": "prompt", "instruction": "Summarize: {{text}}"}
            }
            """,
            named: "summarize.json",
            in: directory
        )
        let tools = makeRegistry(directory: directory).load()
        let tool = try #require(tools.first)
        #expect(tool.approval == .never)
        guard case .prompt(let prompt) = tool.body else {
            Issue.record("Expected a prompt body")
            return
        }
        #expect(prompt.instruction == "Summarize: {{text}}")
    }

    @Test("a workflow spec loads as one user-facing tool")
    func validWorkflowSpec() throws {
        let directory = try makeTemporaryDirectory()
        try writeSpec(
            """
            {
              "name": "weather_brief",
              "description": "Fetches weather, applies a local rule, and explains the result.",
              "arguments": {
                "type": "object",
                "properties": {
                  "city": {"type": "string"}
                },
                "required": ["city"]
              },
              "body": {
                "kind": "workflow",
                "steps": [
                  {
                    "id": "forecast",
                    "permission": "inherit",
                    "payload": {"fetch": {"url": "https://weather.example/forecast?city={{city}}"}},
                    "saveAs": "forecast"
                  },
                  {
                    "id": "rule",
                    "permission": "inherit",
                    "payload": {"execute": {"script": {"path": "rule.py"}, "interpreter": "python3"}},
                    "inputs": {"weather": "forecast"},
                    "saveAs": "rule_result"
                  },
                  {
                    "id": "explain",
                    "permission": "inherit",
                    "payload": {"think": {"instruction": "Explain {{rule_result}} using {{city}}."}}
                  }
                ]
              }
            }
            """,
            named: "weather.json",
            in: directory
        )

        let capture = LoadCapture()
        let tools = makeRegistry(directory: directory, capture: capture).load()

        let tool = try #require(tools.first)
        #expect(tools.count == 1)
        #expect(tool.name == "weather_brief")
        #expect(tool.approval == .always)
        #expect(tool.argumentNames == ["city"])
        guard case .workflow(let workflow) = tool.body else {
            Issue.record("Expected a workflow body")
            return
        }
        #expect(workflow.steps.map(\.kind) == [.fetch, .execute, .think])
        #expect(workflow.steps[1].outputName == "rule_result")
        capture.issues.withLock { #expect($0.isEmpty) }
    }

    @Test("an invalid workflow is rejected before it reaches the model")
    func invalidWorkflowSpec() throws {
        let directory = try makeTemporaryDirectory()
        try writeSpec(
            """
            {
              "name": "broken_workflow",
              "description": "Has a duplicate step id.",
              "body": {
                "kind": "workflow",
                "steps": [
                  {"id": "same", "permission": "inherit", "payload": {"fetch": {"url": "https://example.com"}}},
                  {"id": "same", "permission": "inherit", "payload": {"think": {"instruction": "Nope"}}}
                ]
              }
            }
            """,
            named: "broken-workflow.json",
            in: directory
        )

        let capture = LoadCapture()
        #expect(makeRegistry(directory: directory, capture: capture).load().isEmpty)
        let issues = capture.issues.withLock { $0 }
        #expect(issues.count == 1)
        if case .invalidSpec(let message) = issues[0].reason {
            #expect(message.contains("duplicated"))
        } else {
            Issue.record("Expected an invalidSpec issue")
        }
    }

    @Test("unknown placeholders fail validation and are reported")
    func unknownPlaceholder() throws {
        let directory = try makeTemporaryDirectory()
        try writeSpec(
            """
            {
              "name": "broken",
              "description": "References an undeclared argument.",
              "arguments": {"type": "object", "properties": {"a": {"type": "string"}}},
              "body": {"kind": "prompt", "instruction": "Run with {{b}}"}
            }
            """,
            named: "broken.json",
            in: directory
        )
        let capture = LoadCapture()
        let tools = makeRegistry(directory: directory, capture: capture).load()
        #expect(tools.isEmpty)
        let issues = capture.issues.withLock { $0 }
        #expect(issues.count == 1)
        if case .invalidSpec(let message) = issues[0].reason {
            #expect(message.contains("{{b}}"))
        } else {
            Issue.record("Expected an invalidSpec issue, got \(issues[0].reason)")
        }
    }

    @Test("duplicate names keep the first file and report the rest")
    func duplicateNames() throws {
        let directory = try makeTemporaryDirectory()
        let spec = """
            {
              "name": "same",
              "description": "A tool.",
              "body": {"kind": "wasm", "module": "same.wasm"}
            }
            """
        try writeSpec(spec, named: "a.json", in: directory)
        try writeSpec(spec, named: "b.json", in: directory)
        let capture = LoadCapture()
        let tools = makeRegistry(directory: directory, capture: capture).load()
        #expect(tools.count == 1)
        capture.issues.withLock { issues in
            #expect(issues.count == 1)
            if case .duplicateName(let name) = issues[0].reason {
                #expect(name == "same")
            } else {
                Issue.record("Expected a duplicateName issue")
            }
        }
    }

    @Test("invalid JSON and unknown body kinds are reported, valid siblings still load")
    func invalidFilesDoNotBreakSiblings() throws {
        let directory = try makeTemporaryDirectory()
        try writeSpec("not json", named: "garbage.json", in: directory)
        try writeSpec(
            """
            {
              "name": "weird",
              "description": "Unknown kind.",
              "body": {"kind": "mystery"}
            }
            """,
            named: "weird.json",
            in: directory
        )
        try writeSpec(
            """
            {
              "name": "fine",
              "description": "Loads fine.",
              "body": {"kind": "wasm", "module": "fine.wasm"}
            }
            """,
            named: "fine.json",
            in: directory
        )
        let capture = LoadCapture()
        let tools = makeRegistry(directory: directory, capture: capture).load()
        #expect(tools.map(\.name) == ["fine"])
        capture.issues.withLock { #expect($0.count == 2) }
    }

    @Test("deleting a spec removes the tool on the next load")
    func deletionTakesEffectOnNextLoad() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("temp.json")
        try """
        {
          "name": "temp",
          "description": "Short-lived.",
          "body": {"kind": "wasm", "module": "temp.wasm"}
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        let registry = makeRegistry(directory: directory)
        #expect(registry.load().count == 1)
        try FileManager.default.removeItem(at: file)
        #expect(registry.load().isEmpty)
    }

    @Test("the dashboard document API validates, saves, reads, and deletes")
    func documentLifecycle() throws {
        let directory = try makeTemporaryDirectory()
        let registry = UserToolRegistry(directory: directory)
        let contents = """
            {
              "name": "echo",
              "description": "Echoes a value.",
              "body": {"kind": "process", "argv": ["/bin/echo", "hello"]}
            }
            """

        try registry.save(named: "echo.json", contents: contents)
        let document = try #require(registry.document(named: "echo.json"))
        #expect(document.isValid)
        #expect(document.contents == contents)
        #expect(document.tool?.name == "echo")

        try registry.delete(named: "echo.json")
        #expect(registry.documents().isEmpty)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("turgai-usertools-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
