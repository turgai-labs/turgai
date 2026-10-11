import AnyLanguageModel
import Hail
import Synchronization
import Testing
import TurgaiApplication

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

private struct WorkflowFixture {
    let directory: URL
    let source: URL
    let script: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turgai-workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        source = directory.appendingPathComponent("weather.json")
        script = directory.appendingPathComponent("rule.py")
        try Data("print('unused in fake dependency')".utf8).write(to: script)
        try Data("{}".utf8).write(to: source)
    }
}

private final class WorkflowCapture: Sendable {
    let events = Mutex<[String]>([])
    let networkRequests = Mutex<[NetworkRequest]>([])
    let processRequests = Mutex<[ProcessRequest]>([])

    func networkDependency() -> NetworkDependency {
        NetworkDependency { [self] request in
            events.withLock { $0.append("fetch") }
            networkRequests.withLock { $0.append(request) }
            return NetworkResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"temperature":4,"condition":"cold"}"#.utf8)
            )
        }
    }

    func processDependency() -> ProcessDependency {
        ProcessDependency { [self] request in
            events.withLock { $0.append("execute") }
            processRequests.withLock { $0.append(request) }
            return ProcessResult(
                exitCode: 0,
                standardOutput: Data(#"{"recommendation":"take a coat"}"#.utf8)
            )
        }
    }
}

private func workflowArguments(_ json: String) -> GeneratedContent {
    try! GeneratedContent(json: json)
}

private func makeWorkflowTool(
    fixture: WorkflowFixture,
    steps: [UserTool.WorkflowStep],
    approval: UserTool.ApprovalPolicy = .never
) -> UserWorkflowTool {
    let arguments = try! JSONDecoder().decode(
        GenerationSchema.self,
        from: Data(#"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#.utf8)
    )
    let userTool = UserTool(
        name: "weather_brief",
        description: "Fetches and processes weather.",
        approval: approval,
        arguments: arguments,
        body: .workflow(UserTool.Workflow(steps: steps)),
        source: fixture.source
    )
    return UserWorkflowTool(
        tool: userTool,
        workspaceRoot: fixture.directory.path,
        approval: NoOpApproval()
    )
}

@Suite("User workflow tool")
struct UserWorkflowToolTests {
    @Test("runs stages in order and passes named output to the next stage")
    func runsSequentially() async throws {
        let fixture = try WorkflowFixture()
        let tool = makeWorkflowTool(
            fixture: fixture,
            steps: [
                UserTool.WorkflowStep(
                    id: "forecast",
                    payload: .fetch(
                        .init(url: "https://weather.example/forecast?city={{city}}")
                    )
                ),
                UserTool.WorkflowStep(
                    id: "rule",
                    saveAs: "decision",
                    inputs: ["weather": "forecast"],
                    payload: .execute(
                        .init(
                            script: .path(fixture.script.lastPathComponent),
                            interpreter: "/bin/sh",
                            arguments: ["--city", "{{city}}"],
                            writeDirectory: "reports"
                        )
                    )
                ),
            ]
        )
        let capture = WorkflowCapture()

        let output = try await withDependencies({ dependencies in
            dependencies.network = capture.networkDependency()
            dependencies.process = capture.processDependency()
        }) {
            try await tool.runOutput(
                input: workflowArguments(#"{"city":"Berlin"}"#),
                authority: FullAuthority()
            )
        }

        #expect(output.result.textRepresentation.contains("take a coat"))
        #expect(capture.events.withLock { $0 } == ["fetch", "execute"])

        let requests = capture.networkRequests.withLock { $0 }
        #expect(requests.count == 1)
        #expect(requests[0].url == "https://weather.example/forecast?city=Berlin")

        let processRequests = capture.processRequests.withLock { $0 }
        #expect(processRequests.count == 1)
        #expect(processRequests[0].executable == "/bin/sh")
        #expect(processRequests[0].arguments == [fixture.script.path, "--city", "Berlin"])
        #expect(
            String(decoding: processRequests[0].standardInput ?? Data(), as: UTF8.self)
                .contains("weather"))
        #expect(processRequests[0].sandbox?.network == .denied)
        #expect(
            processRequests[0].sandbox?.readWritePaths == [
                fixture.directory.appendingPathComponent("reports").path
            ])
    }

    @Test("opens the next capability only when its stage is reached")
    func childAuthorityIsEnforced() async throws {
        let fixture = try WorkflowFixture()
        let tool = makeWorkflowTool(
            fixture: fixture,
            steps: [
                UserTool.WorkflowStep(
                    id: "forecast",
                    payload: .fetch(.init(url: "https://weather.example/forecast"))
                )
            ]
        )
        let capture = WorkflowCapture()
        let authority = CompositeAuthority()
            .grantingAll(for: UserWorkflowEffect.self)
            .granting(for: NetworkEffect.self) { _ in .denied("network closed") }

        await #expect(throws: EffectDenied.self) {
            try await withDependencies({ dependencies in
                dependencies.network = capture.networkDependency()
            }) {
                try await tool.runOutput(
                    input: workflowArguments(#"{"city":"Berlin"}"#),
                    authority: authority
                )
            }
        }

        #expect(capture.networkRequests.withLock { $0.isEmpty })
    }

    @Test("whole-string references preserve strings while structured values stay JSON")
    func rendersReferences() async throws {
        let fixture = try WorkflowFixture()
        let tool = makeWorkflowTool(
            fixture: fixture,
            steps: [
                UserTool.WorkflowStep(
                    id: "rule",
                    payload: .execute(
                        .init(
                            script: .path(fixture.script.lastPathComponent),
                            interpreter: "/bin/sh",
                            arguments: ["{{city}}", "{{input}}"]
                        )
                    )
                )
            ]
        )
        let capture = WorkflowCapture()
        let input = workflowArguments(#"{"city":"Berlin"}"#)
        _ = try await withDependencies({ dependencies in
            dependencies.process = capture.processDependency()
        }) {
            try await tool.runOutput(input: input, authority: FullAuthority())
        }
        let request = try #require(capture.processRequests.withLock { $0.first })
        #expect(request.arguments == [fixture.script.path, "Berlin", #"{"city":"Berlin"}"#])
    }
}
