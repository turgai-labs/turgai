import AnyLanguageModel
import Hail
import HailCore
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A user-authored native process tool.
///
/// This is the compatibility path for ordinary Swift programs and other host
/// executables. It requests Hail's portable native-process sandbox by default;
/// the live dependency translates that policy to the host platform. Arguments
/// are delivered through rendered argv and environment values; the process
/// body does not receive an implicit JSON stdin stream. The explicit Wasm body
/// remains the stronger capability-isolated alternative.
public struct UserProcessTool: HailCore.Tool {
    public typealias Input = GeneratedContent
    public typealias Effect = ProcessEffect

    public let tool: UserTool
    public let workspaceRoot: String
    public let approval: any ToolApproval
    public let maximumOutputCharacters: Int
    public let conversationID: String
    public let requesterID: String
    public let turnID: String

    public init(
        tool: UserTool,
        workspaceRoot: String,
        approval: any ToolApproval,
        maximumOutputCharacters: Int = 4096,
        conversationID: String = "unknown",
        requesterID: String = "unknown",
        turnID: String = "unknown"
    ) {
        self.tool = tool
        self.workspaceRoot = workspaceRoot
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

    public func effect(for input: GeneratedContent) throws -> ProcessEffect {
        guard case .process = tool.body else {
            throw ToolError.invalidArgument("body", value: "not a process tool")
        }
        let argv = try tool.renderProcess(input)
        let environment = try tool.renderProcessEnvironment(input)
        let executable = UserProcessSupport.resolveExecutable(
            argv[0],
            relativeTo: workspaceRoot,
            pathEnvironment: environment?["PATH"]
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? "/usr/bin:/bin:/usr/local/bin"
        )
        return ProcessEffect(
            executable: executable,
            arguments: Array(argv.dropFirst()),
            cwd: workspaceRoot,
            environment: environment,
            sandbox: UserProcessSupport.sandboxPolicy(
                toolDirectory: tool.source.deletingLastPathComponent().path,
                workspaceRoot: workspaceRoot,
                executable: executable
            ),
            maximumOutputBytes: UserProcessSupport.maximumOutputBytes
        )
    }

    public func runOutput(
        input: GeneratedContent,
        token: borrowing EffectToken<ProcessEffect>
    ) async throws -> ToolOutput {
        if tool.approval == .always {
            let request = token.withConfiguration { effect in
                ApprovalRequest(
                    toolName: name,
                    arguments: input,
                    command: [effect.executable] + effect.arguments,
                    workingDirectory: effect.cwd,
                    conversationID: conversationID,
                    requesterID: requesterID,
                    turnID: turnID
                )
            }
            let decision: ApprovalDecision
            do {
                decision = try await approval.decide(request)
            } catch {
                return .text("Could not ask for approval to run \(name): \(error)")
            }
            guard decision == .granted else {
                return .text("The user declined to run \(name).")
            }
        }

        guard FileManager.default.fileExists(atPath: tool.source.path) else {
            return .text("The user tool \(name) is no longer available.")
        }
        let result = try await ProcessEffect.run(in: token)
        return .text(Self.present(result, maximumCharacters: maximumOutputCharacters))
    }

    public static func present(_ result: ProcessResult, maximumCharacters: Int) -> String {
        var parts: [String] = []
        let stdout = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        parts.append(stdout.isEmpty ? "(no output)" : Self.cap(stdout, maximumCharacters))
        if result.exitCode != 0 {
            parts.append("(exit code \(result.exitCode))")
        }
        let stderr = String(decoding: result.standardError, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        if !stderr.isEmpty {
            parts.append("stderr: \(Self.cap(stderr, maximumCharacters))")
        }
        return parts.joined(separator: "\n")
    }

    private static func cap(_ text: String, _ maximum: Int) -> String {
        text.count > maximum ? String(text.prefix(maximum)) + "… (truncated)" : text
    }
}
