import AnyLanguageModel
import Hail
import HailCore
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A user-authored WebAssembly tool.
///
/// The model input remains ``GeneratedContent`` all the way from Hail's tool
/// boundary to the effect. The runner receives its JSON representation on
/// stdin; the Wasm module owns the meaning of that JSON and writes its result
/// to stdout. The module never becomes a native executable or a shell command.
public struct UserWasmTool: HailCore.Tool {
    public typealias Input = GeneratedContent
    public typealias Effect = ProcessEffect

    public let tool: UserTool
    public let runnerURL: URL
    public let workspaceRoot: String
    public let approval: any ToolApproval
    public let maximumOutputCharacters: Int
    public let conversationID: String
    public let requesterID: String
    public let turnID: String

    public init(
        tool: UserTool,
        runnerURL: URL,
        workspaceRoot: String,
        approval: any ToolApproval,
        maximumOutputCharacters: Int = 4096,
        conversationID: String = "unknown",
        requesterID: String = "unknown",
        turnID: String = "unknown"
    ) {
        self.tool = tool
        self.runnerURL = runnerURL
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
        guard case .wasm(let wasm) = tool.body else {
            throw ToolError.invalidArgument("body", value: "not a wasm tool")
        }

        let moduleURL = try Self.validatedModuleURL(
            wasm.module,
            toolDirectory: tool.source.deletingLastPathComponent()
        )
        let runner = runnerURL.standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: runner.path) else {
            throw ToolError.notConfigured("TurgaiWasmRunner is not executable: \(runner.path)")
        }

        return ProcessEffect(
            executable: runner.path,
            arguments: ["--module", moduleURL.path],
            cwd: workspaceRoot,
            standardInput: Data(input.jsonString.utf8),
            sandbox: UserProcessSupport.sandboxPolicy(
                toolDirectory: tool.source.deletingLastPathComponent().path,
                workspaceRoot: workspaceRoot,
                executable: runner.path,
                allowWorkspaceWrite: false
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

        // A spec or module can be removed while Telegram approval is pending.
        // Re-check the data boundary immediately before the process starts.
        guard FileManager.default.fileExists(atPath: tool.source.path) else {
            return .text("The user tool \(name) is no longer available.")
        }
        let moduleIsAvailable = token.withConfiguration { effect in
            guard effect.arguments.count == 2, effect.arguments[0] == "--module" else {
                return false
            }
            let moduleURL = URL(fileURLWithPath: effect.arguments[1])
            return
                (try? Self.validatedModuleURL(
                    moduleURL,
                    toolDirectory: tool.source.deletingLastPathComponent()
                )) != nil
        }
        guard moduleIsAvailable else {
            return .text("The WebAssembly module for \(name) is no longer available.")
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

    private static func validatedModuleURL(
        _ moduleURL: URL,
        toolDirectory: URL
    ) throws -> URL {
        let root = toolDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = moduleURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw ToolError.notConfigured("WebAssembly module is outside the tool directory")
        }
        guard candidate.pathExtension.lowercased() == "wasm" else {
            throw ToolError.notConfigured("WebAssembly module must have a .wasm extension")
        }
        guard FileManager.default.isReadableFile(atPath: candidate.path) else {
            throw ToolError.notConfigured("WebAssembly module is not readable: \(candidate.path)")
        }
        return candidate
    }

    private static func cap(_ text: String, _ maximum: Int) -> String {
        text.count > maximum ? String(text.prefix(maximum)) + "… (truncated)" : text
    }
}
