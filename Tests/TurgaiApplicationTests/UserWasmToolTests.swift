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

private struct WasmFixture {
    let directory: URL
    let source: URL
    let module: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turgai-wasm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        source = directory.appendingPathComponent("shout.json")
        module = directory.appendingPathComponent("shout.wasm")
        try Data("placeholder module".utf8).write(to: module)
        try Data("{}".utf8).write(to: source)
    }
}

private func makeWasmTool(
    runnerPath: String = "/bin/sh"
) throws -> (tool: UserWasmTool, fixture: WasmFixture) {
    let fixture = try WasmFixture()
    let arguments = try JSONDecoder().decode(
        GenerationSchema.self,
        from: Data(#"{"type":"object","properties":{"words":{"type":"string"}},"required":["words"]}"#.utf8)
    )
    let userTool = UserTool(
        name: "shout",
        description: "Runs a Wasm module.",
        arguments: arguments,
        body: .wasm(UserTool.Wasm(module: fixture.module)),
        source: fixture.source
    )
    return (
        UserWasmTool(
            tool: userTool,
            runnerURL: URL(fileURLWithPath: runnerPath),
            workspaceRoot: fixture.directory.path
        ),
        fixture
    )
}

private final class ProcessCapture: Sendable {
    let requests = Mutex<[ProcessRequest]>([])

    func dependency(
        result: ProcessResult = ProcessResult(
            exitCode: 0,
            standardOutput: Data("module result".utf8)
        )
    ) -> ProcessDependency {
        ProcessDependency { [self] request in
            requests.withLock { $0.append(request) }
            return result
        }
    }
}

private func arguments(_ json: String) -> GeneratedContent {
    try! GeneratedContent(json: json)
}

@Suite("User Wasm tool")
struct UserWasmToolTests {
    @Test("effect derivation keeps GeneratedContent as JSON stdin")
    func effectDerivation() throws {
        let (tool, fixture) = try makeWasmTool()
        let input = arguments(#"{"words":"hi"}"#)
        let effect = try tool.effect(for: input)

        #expect(effect.executable == "/bin/sh")
        #expect(effect.arguments == ["--module", fixture.module.path])
        #expect(effect.cwd == fixture.directory.path)
        #expect(effect.standardInput == Data(input.jsonString.utf8))
        #expect(effect.sandbox?.network == .denied)
        #expect(effect.sandbox?.readWritePaths.isEmpty == true)
    }

    @Test("a run sends the JSON request to the process dependency")
    func approvedRun() async throws {
        let (tool, fixture) = try makeWasmTool()
        let capture = ProcessCapture()
        let input = arguments(#"{"words":"hello"}"#)
        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
        #expect(FileManager.default.isReadableFile(atPath: fixture.module.path))
        _ = try tool.effect(for: input)
        let output = try await withDependencies { dependencies in
            dependencies.process = capture.dependency()
        } operation: {
            try await tool.runOutput(input: input, authority: FullAuthority())
        }

        #expect(output.result.textRepresentation == "module result")
        let requests = capture.requests.withLock { $0 }
        #expect(requests.count == 1)
        #expect(requests[0].standardInput == Data(input.jsonString.utf8))
        #expect(requests[0].arguments == ["--module", fixture.module.path])
    }

    @Test("an ungranted authority denies the run")
    func ungrantedAuthority() async throws {
        struct DenyAll: Authority {
            func decision<Effect: ScopedEffect>(on effect: Effect) -> EffectDecision {
                .denied("closed")
            }
        }

        let (tool, _) = try makeWasmTool()
        await #expect(throws: (any Error).self) {
            try await tool.runOutput(
                input: arguments(#"{"words":"hi"}"#),
                authority: DenyAll()
            )
        }
    }

    @Test("a removed module is not started after the effect was authorized")
    func removedModuleIsRejectedBeforeStart() async throws {
        let (tool, fixture) = try makeWasmTool()
        let effect = try tool.effect(for: arguments(#"{"words":"hi"}"#))
        try FileManager.default.removeItem(at: fixture.module)
        let capture = ProcessCapture()
        let output = try await withDependencies { dependencies in
            dependencies.process = capture.dependency()
        } operation: {
            try await withEffect(effect, authority: FullAuthority()) { token in
                try await tool.runOutput(
                    input: arguments(#"{"words":"hi"}"#),
                    token: token
                )
            }
        }
        #expect(output.result.textRepresentation.contains("no longer available"))
        #expect(capture.requests.withLock { $0.isEmpty })
    }

    @Test("presentation caps output and reports exit codes")
    func presentation() {
        let result = ProcessResult(
            exitCode: 3,
            standardOutput: Data(String(repeating: "x", count: 10_000).utf8),
            standardError: Data("oops".utf8)
        )
        let text = UserWasmTool.present(result, maximumCharacters: 100)
        #expect(text.contains("(exit code 3)"))
        #expect(text.contains("stderr: oops"))
        #expect(text.contains("truncated"))
        #expect(!text.contains(String(repeating: "x", count: 101)))
    }
}
