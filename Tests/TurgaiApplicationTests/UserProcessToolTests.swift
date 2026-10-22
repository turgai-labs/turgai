import AnyLanguageModel
import Hail
import Synchronization
import Testing
import TurgaiApplication
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

private struct ProcessFixture {
    let directory: URL
    let source: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turgai-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        source = directory.appendingPathComponent("tool.json")
        try Data("{}".utf8).write(to: source)
    }
}

private func makeProcessTool(
    approval: any ToolApproval = NoOpApproval()
) throws -> (tool: UserProcessTool, fixture: ProcessFixture) {
    let fixture = try ProcessFixture()
    let arguments = try JSONDecoder().decode(
        GenerationSchema.self,
        from: Data(#"{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}"#.utf8)
    )
    let userTool = UserTool(
        name: "native_echo",
        description: "Runs a native program.",
        approval: .always,
        arguments: arguments,
        body: .process(
            UserTool.NativeProcess(
                argv: ["/bin/sh", "-c", "printf '%s' '{{value}}'"],
                environment: ["TOOL_VALUE": "{{value}}"]
            )),
        source: fixture.source
    )
    return (
        UserProcessTool(
            tool: userTool,
            workspaceRoot: fixture.directory.path,
            approval: approval
        ),
        fixture
    )
}

private struct DenyingProcessApproval: ToolApproval {
    func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision { .denied }
}

private final class ProcessCapture: Sendable {
    let requests = Mutex<[ProcessRequest]>([])

    func dependency() -> ProcessDependency {
        ProcessDependency { [self] request in
            requests.withLock { $0.append(request) }
            return ProcessResult(
                exitCode: 0,
                standardOutput: Data("native result".utf8)
            )
        }
    }
}

private func arguments(_ json: String) -> GeneratedContent {
    try! GeneratedContent(json: json)
}

@Suite("User native process tool")
struct UserProcessToolTests {
    @Test("process templates render argv and environment")
    func rendersTemplates() throws {
        let (tool, _) = try makeProcessTool()
        let input = arguments(#"{"value":"hello world"}"#)
        let argv = try tool.tool.renderProcess(input)
        let environment = try tool.tool.renderProcessEnvironment(input)

        #expect(argv == ["/bin/sh", "-c", "printf '%s' 'hello world'"])
        #expect(environment == ["TOOL_VALUE": "hello world"])
    }

    @Test("effect derivation creates a native process from argv and environment")
    func effectDerivation() throws {
        let (tool, fixture) = try makeProcessTool()
        let input = arguments(#"{"value":"hello"}"#)
        let effect = try tool.effect(for: input)

        #expect(effect.executable == "/bin/sh")
        #expect(effect.arguments == ["-c", "printf '%s' 'hello'"])
        #expect(effect.cwd == fixture.directory.path)
        #expect(effect.environment == ["TOOL_VALUE": "hello"])
        #expect(effect.standardInput == nil)
        #expect(effect.sandbox?.network == .denied)
        #expect(effect.sandbox?.environment == .clear)
        #expect(effect.sandbox?.readWritePaths == [fixture.directory.path])
    }

    @Test("an approved run invokes the process dependency")
    func approvedRun() async throws {
        let (tool, _) = try makeProcessTool()
        let input = arguments(#"{"value":"hello"}"#)
        let capture = ProcessCapture()
        let output = try await withDependencies { dependencies in
            dependencies.process = capture.dependency()
        } operation: {
            try await tool.runOutput(input: input, authority: FullAuthority())
        }

        #expect(output.result.textRepresentation == "native result")
        let requests = capture.requests.withLock { $0 }
        #expect(requests.count == 1)
        #expect(requests[0].executable == "/bin/sh")
        #expect(requests[0].standardInput == nil)
    }

    @Test("a declined approval does not invoke the process")
    func declinedApproval() async throws {
        let (tool, _) = try makeProcessTool(approval: DenyingProcessApproval())
        let output = try await tool.runOutput(
            input: arguments(#"{"value":"hello"}"#),
            authority: FullAuthority()
        )
        #expect(output.result.textRepresentation == "The user declined to run native_echo.")
    }
}
