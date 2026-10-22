import AnyLanguageModel
import DistributedCluster
import Hail
import HailCore
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The authority-gated invocation of a user-facing workflow. The workflow is
/// configuration; its individual stages are opened dynamically by
/// ``UserWorkflowRunner`` through the token this effect vends.
public struct UserWorkflowEffect: ScopedEffect, Sendable {
    public let name = "user-workflow"
    public let workflow: UserTool.Workflow
    public let input: GeneratedContent
    public let toolDirectory: URL
    public let workspaceRoot: String
    public let toolName: String

    public init(
        workflow: UserTool.Workflow,
        input: GeneratedContent,
        toolDirectory: URL,
        workspaceRoot: String,
        toolName: String
    ) {
        self.workflow = workflow
        self.input = input
        self.toolDirectory = toolDirectory
        self.workspaceRoot = workspaceRoot
        self.toolName = toolName
    }

    /// User workflows are entered through ``UserWorkflowTool``, which owns
    /// the host services needed by `think` stages. Keeping this fallback
    /// unavailable prevents a caller from accidentally bypassing that
    /// context while still making the workflow itself a normal scoped effect.
    public static func run(
        in token: borrowing EffectToken<UserWorkflowEffect>
    ) async throws {
        _ = token
        throw UserWorkflowError.requiresToolRunner
    }
}

public enum UserWorkflowError: Error, Sendable, Equatable, CustomStringConvertible {
    case requiresToolRunner
    case emptyWorkflow
    case invalidReference(String)
    case invalidTemplate(String)
    case invalidURL(String)
    case unsupportedURLScheme(String)
    case networkStatus(step: String, statusCode: Int)
    case invalidProcessOutput(step: String)
    case processFailed(step: String, exitCode: Int32, stderr: String)
    case invalidScriptPath(String)
    case scriptUnavailable(String)
    case missingThinkAgent

    public var description: String {
        switch self {
        case .requiresToolRunner:
            return "A user workflow must be run through UserWorkflowTool."
        case .emptyWorkflow:
            return "The workflow has no steps."
        case .invalidReference(let reference):
            return "Workflow reference '\(reference)' could not be resolved."
        case .invalidTemplate(let template):
            return "Workflow template is invalid: \(template)"
        case .invalidURL(let url):
            return "Workflow URL is invalid: \(url)"
        case .unsupportedURLScheme(let scheme):
            return "Workflow URL scheme is not supported: \(scheme)"
        case .networkStatus(let step, let statusCode):
            return "Fetch step '\(step)' returned HTTP status \(statusCode)."
        case .invalidProcessOutput(let step):
            return "Execute step '\(step)' returned invalid output."
        case .processFailed(let step, let exitCode, let stderr):
            let detail = stderr.isEmpty ? "" : ": \(stderr)"
            return "Execute step '\(step)' exited with code \(exitCode)\(detail)"
        case .invalidScriptPath(let path):
            return "Script path is outside the tool directory or invalid: \(path)"
        case .scriptUnavailable(let path):
            return "Script is not readable: \(path)"
        case .missingThinkAgent:
            return "Think stages require an agent runtime."
        }
    }
}

/// The workflow-local half of the authority intersection. It recognizes only
/// the concrete child operations created by this workflow; all unrelated
/// effects are left to the lane authority. The lane authority is still
/// evaluated by ``IntersectingAuthority`` and can never be widened here.
private struct UserWorkflowStageAuthority: Authority {
    private let fetchSteps: [String: UserTool.WorkflowStep]
    private let executeSteps: [String: UserTool.WorkflowStep]
    private let thinkSteps: [String: UserTool.WorkflowStep]
    private let workspaceRoot: String

    init(toolName: String, workflow: UserTool.Workflow, workspaceRoot: String) {
        var fetchSteps: [String: UserTool.WorkflowStep] = [:]
        var executeSteps: [String: UserTool.WorkflowStep] = [:]
        var thinkSteps: [String: UserTool.WorkflowStep] = [:]

        for step in workflow.steps {
            switch step.kind {
            case .fetch:
                fetchSteps["workflow.fetch.\(toolName).\(step.id)"] = step
            case .execute:
                executeSteps["workflow.execute.\(toolName).\(step.id)"] = step
            case .think:
                thinkSteps["think.\(toolName).\(step.id)"] = step
            }
        }

        self.fetchSteps = fetchSteps
        self.executeSteps = executeSteps
        self.thinkSteps = thinkSteps
        self.workspaceRoot = workspaceRoot
    }

    func decision<Effect: ScopedEffect>(on effect: Effect) -> EffectDecision {
        if effect is UserWorkflowEffect {
            return .granted
        }
        if let fetch = effect as? NetworkEffect,
            let step = fetchSteps[fetch.operation]
        {
            return decision(for: step, host: fetch.host)
        }
        if let execute = effect as? ProcessEffect,
            let operation = execute.operation,
            let step = executeSteps[operation]
        {
            return decision(for: step, process: execute)
        }
        if let think = effect as? CoordinationEffect,
            let step = thinkSteps[think.action]
        {
            return decision(for: step)
        }
        return .denied(
            "effect '\(effect.name)' is not a declared stage of this workflow"
        )
    }

    private func decision(
        for step: UserTool.WorkflowStep,
        host: String? = nil,
        process: ProcessEffect? = nil
    ) -> EffectDecision {
        if step.permission == .denied {
            return .denied("workflow stage '\(step.id)' is disabled")
        }

        if let process {
            guard let sandbox = process.sandbox else {
                return .denied(
                    "workflow execute stage '\(step.id)' requires a process sandbox"
                )
            }
            let expected =
                (try? UserProcessSupport.workspaceDirectory(
                    step.writeDirectory,
                    workspaceRoot: workspaceRoot
                )) ?? ""
            let actual = sandbox.readWritePaths.map(Self.canonicalPath)
            guard actual.count == 1,
                actual[0] == Self.canonicalPath(expected)
            else {
                return .denied(
                    "workflow execute stage '\(step.id)' has an unexpected writable directory"
                )
            }
        }

        guard let allowedHosts = step.allowedHosts, let host else {
            return .granted
        }
        let normalizedHost = Self.normalizeHost(host)
        guard allowedHosts.contains(where: { Self.normalizeHost($0) == normalizedHost }) else {
            return .denied("workflow stage '\(step.id)' does not allow host '\(host)'")
        }
        return .granted
    }

    private static func normalizeHost(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL
            .resolvingSymlinksInPath().path
    }
}

/// Exposes a user workflow to the model as one tool. The model sees only the
/// workflow's name, description, and `@Generable`-compatible argument schema;
/// the stages remain a private user-facing configuration.
public struct UserWorkflowTool: HailCore.Tool {
    public typealias Input = GeneratedContent
    public typealias Effect = UserWorkflowEffect

    public let tool: UserTool
    public let workspaceRoot: String
    public let actorSystem: ClusterSystem?
    public let sourceAgentID: AgentID?
    public let approval: any ToolApproval
    public let maximumOutputCharacters: Int
    public let conversationID: String
    public let requesterID: String
    public let turnID: String

    public init(
        tool: UserTool,
        workspaceRoot: String,
        actorSystem: ClusterSystem? = nil,
        sourceAgentID: AgentID? = nil,
        approval: any ToolApproval,
        maximumOutputCharacters: Int = 4096,
        conversationID: String = "unknown",
        requesterID: String = "unknown",
        turnID: String = "unknown"
    ) {
        self.tool = tool
        self.workspaceRoot = workspaceRoot
        self.actorSystem = actorSystem
        self.sourceAgentID = sourceAgentID
        self.approval = approval
        self.maximumOutputCharacters = max(1, maximumOutputCharacters)
        self.conversationID = conversationID
        self.requesterID = requesterID
        self.turnID = turnID
    }

    public var name: String { tool.name }
    public var description: String { tool.description }
    public var schema: ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: tool.arguments)
    }
    public var authorityRestriction: (any Authority)? {
        guard case .workflow(let workflow) = tool.body else { return nil }
        return UserWorkflowStageAuthority(
            toolName: name,
            workflow: workflow,
            workspaceRoot: workspaceRoot
        )
    }

    public func effect(for input: GeneratedContent) throws -> UserWorkflowEffect {
        guard case .workflow(let workflow) = tool.body else {
            throw ToolError.invalidArgument("body", value: "not a workflow tool")
        }
        guard !workflow.steps.isEmpty else {
            throw UserWorkflowError.emptyWorkflow
        }
        return UserWorkflowEffect(
            workflow: workflow,
            input: input,
            toolDirectory: tool.source.deletingLastPathComponent(),
            workspaceRoot: workspaceRoot,
            toolName: name
        )
    }

    public func run(
        _ input: GeneratedContent, in scope: borrowing ToolScope<Never>,
        token: borrowing EffectToken<UserWorkflowEffect>
    ) async throws -> CallReturn {
        if tool.approval == .always {
            let decision = try await approval.decide(
                ApprovalRequest(
                    toolName: name,
                    arguments: input,
                    command: ["workflow", name],
                    workingDirectory: workspaceRoot,
                    conversationID: conversationID,
                    requesterID: requesterID,
                    turnID: turnID
                )
            )
            guard decision == .granted else {
                return .text("The user declined to run \(name).")
            }
        }

        // A workflow's specification and scripts may be replaced while the
        // model call is waiting for approval. Do not execute a removed tool.
        guard FileManager.default.fileExists(atPath: tool.source.path) else {
            return .text("The user tool \(name) is no longer available.")
        }

        let result = try await UserWorkflowRunner.run(
            effect: token.withConfiguration { $0 },
            actorSystem: actorSystem,
            sourceAgentID: sourceAgentID,
            turnID: turnID,
            token: token
        )
        return .text(Self.present(result, maximumCharacters: maximumOutputCharacters))
    }

    public static func present(
        _ value: GeneratedContent,
        maximumCharacters: Int
    ) -> String {
        let text: String
        switch value.kind {
        case .string(let string):
            text = string
        default:
            text = value.jsonString
        }
        return text.count > maximumCharacters
            ? String(text.prefix(maximumCharacters)) + "… (truncated)"
            : text
    }
}

private enum UserWorkflowRunner {
    static func run(
        effect: UserWorkflowEffect,
        actorSystem: ClusterSystem?,
        sourceAgentID: AgentID?,
        turnID: String,
        token: borrowing EffectToken<UserWorkflowEffect>
    ) async throws -> GeneratedContent {
        var context = WorkflowContext(input: effect.input)
        var lastValue: GeneratedContent?

        for step in effect.workflow.steps {
            let value: GeneratedContent
            switch step.kind {
            case .fetch:
                value = try await runFetch(
                    step,
                    context: &context,
                    toolName: effect.toolName,
                    token: token
                )

            case .execute:
                value = try await runExecute(
                    step,
                    context: &context,
                    toolName: effect.toolName,
                    toolDirectory: effect.toolDirectory,
                    workspaceRoot: effect.workspaceRoot,
                    token: token
                )

            case .think:
                value = try await runThink(
                    step,
                    context: &context,
                    toolName: effect.toolName,
                    actorSystem: actorSystem,
                    sourceAgentID: sourceAgentID,
                    turnID: turnID,
                    token: token
                )
            }

            context.store(value, as: step.outputName)
            lastValue = value
        }

        guard let lastValue else { throw UserWorkflowError.emptyWorkflow }
        return lastValue
    }

    private static func runFetch(
        _ step: UserTool.WorkflowStep,
        context: inout WorkflowContext,
        toolName: String,
        token: borrowing EffectToken<UserWorkflowEffect>
    ) async throws -> GeneratedContent {
        guard let rawURL = step.url else {
            throw UserWorkflowError.invalidURL("missing URL")
        }
        let urlString = try context.render(rawURL)
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
            throw UserWorkflowError.invalidURL(urlString)
        }
        guard scheme == "http" || scheme == "https" else {
            throw UserWorkflowError.unsupportedURLScheme(scheme)
        }
        guard url.user == nil, url.password == nil, let host = url.host, !host.isEmpty else {
            throw UserWorkflowError.invalidURL(urlString)
        }
        guard !Self.isLocalHost(host) else {
            throw UserWorkflowError.invalidURL("local hosts are not allowed")
        }

        let method = try context.render(step.method ?? "GET")
        guard !method.isEmpty,
            !method.contains(where: { $0 == "\r" || $0 == "\n" })
        else {
            throw UserWorkflowError.invalidURL("invalid HTTP method")
        }
        let headers = try step.headers?.mapValues { try context.render($0) } ?? [:]
        let body: Data?
        if let rawBody = step.body {
            body = Data(try context.render(rawBody).utf8)
        } else {
            body = nil
        }
        let effect = NetworkEffect(
            host: host,
            operation: "workflow.fetch.\(toolName).\(step.id)",
            request: NetworkRequest(
                url: url.absoluteString,
                method: method.uppercased(),
                headers: headers,
                body: body,
                maximumResponseBytes: 16 * 1024 * 1024,
                allowedHosts: step.allowedHosts.map(Set.init)
            )
        )
        let response = try await token.run(effect)
        guard (200..<300).contains(response.statusCode) else {
            throw UserWorkflowError.networkStatus(
                step: step.id,
                statusCode: response.statusCode
            )
        }
        return networkValue(response)
    }

    private static func runExecute(
        _ step: UserTool.WorkflowStep,
        context: inout WorkflowContext,
        toolName: String,
        toolDirectory: URL,
        workspaceRoot: String,
        token: borrowing EffectToken<UserWorkflowEffect>
    ) async throws -> GeneratedContent {
        guard step.script != nil || step.scriptSource != nil else {
            throw UserWorkflowError.scriptUnavailable("missing script")
        }
        if step.script == nil, step.interpreter == nil {
            throw UserWorkflowError.scriptUnavailable("inline script requires an interpreter")
        }
        let scriptURL = try step.script.map {
            try UserProcessSupport.scriptURL($0, toolDirectory: toolDirectory)
        }
        let rawArguments = step.arguments ?? []
        let arguments = try rawArguments.map { try context.render($0) }
        let pathEnvironment =
            step.environment?["PATH"]
            ?? ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin:/usr/local/bin"

        let executable: String
        let processArguments: [String]
        if let interpreter = step.interpreter {
            let renderedInterpreter = try context.render(interpreter)
            executable = UserProcessSupport.resolveExecutable(
                renderedInterpreter,
                relativeTo: workspaceRoot,
                pathEnvironment: pathEnvironment
            )
            processArguments =
                if let scriptURL {
                    [scriptURL.path] + arguments
                } else {
                    // Interpreters assign the first argument after -c to argv[0]
                    // or $0. Give it a stable value so user arguments start at
                    // argv[1] or $1 consistently.
                    ["-c", step.scriptSource ?? "", "turgai-script"] + arguments
                }
        } else {
            guard let scriptURL,
                FileManager.default.isExecutableFile(atPath: scriptURL.path)
            else {
                throw UserWorkflowError.scriptUnavailable(step.script ?? "missing script")
            }
            executable = scriptURL.path
            processArguments = arguments
        }

        let environment = try step.environment?.mapValues { try context.render($0) }
        let input = try context.payload(for: step.inputs)
        let process = ProcessEffect(
            executable: executable,
            arguments: processArguments,
            cwd: toolDirectory.path,
            standardInput: Data(input.jsonString.utf8),
            environment: environment,
            sandbox: UserProcessSupport.sandboxPolicy(
                toolDirectory: toolDirectory.path,
                workspaceRoot: workspaceRoot,
                executable: executable,
                writeDirectory: step.writeDirectory
            ),
            maximumOutputBytes: UserProcessSupport.maximumOutputBytes,
            operation: "workflow.execute.\(toolName).\(step.id)"
        )
        let result = try await token.run(process)
        guard result.exitCode == 0 else {
            throw UserWorkflowError.processFailed(
                step: step.id,
                exitCode: result.exitCode,
                stderr: String(decoding: result.standardError, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return try processValue(result.standardOutput, step: step.id)
    }

    private static func runThink(
        _ step: UserTool.WorkflowStep,
        context: inout WorkflowContext,
        toolName: String,
        actorSystem: ClusterSystem?,
        sourceAgentID: AgentID?,
        turnID: String,
        token: borrowing EffectToken<UserWorkflowEffect>
    ) async throws -> GeneratedContent {
        guard let instruction = step.instruction else {
            throw UserWorkflowError.invalidTemplate("missing think instruction")
        }
        guard let actorSystem, let sourceAgentID else {
            throw UserWorkflowError.missingThinkAgent
        }

        // Coordination is the internal authority/audit gate. The user only
        // sees a Think stage; no Hail effect vocabulary leaks into the spec.
        let gate = CoordinationEffect(
            subsystem: "user-workflow",
            action: "think.\(toolName).\(step.id)"
        )
        _ = try await token.run(gate)

        let renderedInstruction = try context.render(instruction)
        let input = try context.payload(for: step.inputs)
        let prompt = renderedInstruction + "\n\nWorkflow data:\n" + input.jsonString
        let response = try await UserAgentRunner.run(
            instruction: prompt,
            toolName: "\(toolName)-\(step.id)",
            actorSystem: actorSystem,
            sourceAgentID: sourceAgentID,
            turnID: turnID
        )
        return GeneratedContent(response)
    }

    private static func networkValue(_ response: NetworkResponse) -> GeneratedContent {
        let text = String(data: response.body, encoding: .utf8)
        let body: GeneratedContent
        switch (text, text.flatMap({ try? GeneratedContent(json: $0) })) {
        case (_, let json?):
            body = json
        case (let text?, nil):
            body = GeneratedContent(text)
        case (nil, nil):
            body = GeneratedContent(response.body.base64EncodedString())
        }

        let orderedHeaders = response.headers
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
        let headerValues = Dictionary(
            uniqueKeysWithValues: orderedHeaders.map {
                ($0.key, GeneratedContent($0.value))
            })
        let headerContent = GeneratedContent(
            kind: .structure(
                properties: headerValues,
                orderedKeys: orderedHeaders.map { $0.key }
            )
        )
        return GeneratedContent(
            kind: .structure(
                properties: [
                    "status": GeneratedContent(response.statusCode),
                    "headers": headerContent,
                    "body": body,
                ],
                orderedKeys: ["status", "headers", "body"]
            )
        )
    }

    private static func processValue(
        _ data: Data,
        step: String
    ) throws -> GeneratedContent {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return GeneratedContent("")
        }
        if let json = try? GeneratedContent(json: text) {
            return json
        }
        // Plain text is a valid script result. JSON is required only when a
        // later stage needs structured fields from it.
        guard !text.contains("\u{0000}") else {
            throw UserWorkflowError.invalidProcessOutput(step: step)
        }
        return GeneratedContent(text)
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "0.0.0.0"
            || normalized == "::1"
    }
}

private struct WorkflowContext {
    private var values: [String: GeneratedContent]

    init(input: GeneratedContent) {
        values = ["input": input]
    }

    mutating func store(_ value: GeneratedContent, as name: String) {
        values[name] = value
    }

    func resolve(_ reference: String) throws -> GeneratedContent {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else {
            throw UserWorkflowError.invalidReference(reference)
        }

        let components = reference.split(separator: ".").map(String.init)
        guard let first = components.first else {
            throw UserWorkflowError.invalidReference(reference)
        }

        let value: GeneratedContent
        switch values[first] {
        case let direct?:
            value = direct
        case nil:
            guard let input = values["input"],
                case .structure(let properties, _) = input.kind,
                let property = properties[first]
            else {
                throw UserWorkflowError.invalidReference(reference)
            }
            value = property
        }

        var current = value
        for component in components.dropFirst() {
            switch current.kind {
            case .structure(let properties, _):
                guard let next = properties[component] else {
                    throw UserWorkflowError.invalidReference(reference)
                }
                current = next
            case .array(let elements):
                guard let index = Int(component), elements.indices.contains(index) else {
                    throw UserWorkflowError.invalidReference(reference)
                }
                current = elements[index]
            default:
                throw UserWorkflowError.invalidReference(reference)
            }
        }
        return current
    }

    func render(_ template: String) throws -> String {
        var rendered = ""
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            rendered += rest[rest.startIndex..<open.lowerBound]
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "}}") else {
                throw UserWorkflowError.invalidTemplate(template)
            }
            let reference = String(rest[rest.startIndex..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reference.isEmpty else {
                throw UserWorkflowError.invalidTemplate(template)
            }
            let value = try resolve(reference)
            let wholePlaceholder =
                rendered.isEmpty
                && rest[close.upperBound...].isEmpty
                && template.trimmingCharacters(in: .whitespacesAndNewlines)
                    == "{{\(reference)}}"
            if wholePlaceholder {
                if case .string(let string) = value.kind {
                    rendered += string
                } else {
                    rendered += value.jsonString
                }
            } else {
                rendered += Self.stringValue(of: value)
            }
            rest = rest[close.upperBound...]
        }
        rendered += rest
        return rendered
    }

    func payload(
        for inputs: [String: String]?
    ) throws -> GeneratedContent {
        let selected: [(String, GeneratedContent)]
        if let inputs {
            selected = try inputs.sorted { $0.key < $1.key }.map { alias, reference in
                (alias, try resolve(reference))
            }
        } else {
            selected = values.sorted { $0.key < $1.key }
        }
        let pairs = Dictionary(uniqueKeysWithValues: selected)
        return GeneratedContent(
            kind: .structure(
                properties: pairs,
                orderedKeys: selected.map { $0.0 }
            )
        )
    }

    private static func stringValue(of content: GeneratedContent) -> String {
        switch content.kind {
        case .string(let value): value
        case .number(let value):
            value == value.rounded() ? String(Int(value)) : String(describing: value)
        case .bool(let value): value ? "true" : "false"
        case .null: ""
        case .structure, .array: content.jsonString
        }
    }
}
