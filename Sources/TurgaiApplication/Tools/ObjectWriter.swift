import AnyLanguageModel
import Hail
import TurgaiObjects

/// Writes an object's Swift in a session of its own, whose answer is the code: what the object
/// should do goes in, and each answer is saved or comes back with what's wrong, as the next
/// message, until one is saved. The conversation that asked for the object only sees the result,
/// and the writing has a context of its own.
public struct ObjectWriter: Sendable {
    let endpoint: any ModelEndpoint
    /// How many answers it gets to write code that's saved.
    let attempts: Int

    /// Where what happens writing is reported, to read a writing session back.
    let report: (@Sendable (WriterEvent) -> Void)?

    public init(endpoint: any ModelEndpoint, attempts: Int = 4, report: (@Sendable (WriterEvent) -> Void)? = nil) {
        self.endpoint = endpoint
        self.attempts = attempts
        self.report = report
    }

    /// What writing ended with: the code saved, or the last problem with the last code.
    public enum Outcome: Sendable {
        case saved
        case failed(String)
    }

    /// How the runtime runs an object's code, one fact to a line: what the writer has to know to
    /// write it, and nothing it would copy.
    public static let runtime = [
        "Its stored properties start from their default values.",
        "Stored properties are what it keeps; methods are what it can be asked to do.",
        CodableValues.rule,
        ScheduleHandlers.rule,
        "Only the actor goes in the file: code outside it never runs.",
    ]

    /// Writes the actor `type` for `task`, starting from `current` code when it's changed, with
    /// how it last `failure`d running, next to `others`, the objects that exist, as Swift declares
    /// them, and `values`, the structs and enums their values are, in words, for `request`, what
    /// the person asked for, with `runtime`, how the runtime runs it, and `explained`, sections
    /// that explain an idea the code may need, each with its title.
    /// Each answer goes to `save`, which says what's wrong with it, or `nil` when it's saved.
    public func write(
        type: String, task: String, current: String?, failure: String? = nil, others: [String] = [],
        tools: [String] = [], values: [String] = [],
        request: String? = nil,
        runtime: [String] = ObjectWriter.runtime, explained: [String] = [RuntimeMacros.declared],
        isolation: isolated (any Actor)? = #isolation,
        save: (String) async -> String?
    ) async throws -> Outcome {
        // The job first: what to write, what was asked, and its part in it.
        var parts: [String] = []
        if current == nil {
            parts.append(
                (["Write one Swift actor, `actor \(type)`, with only the standard library."]
                    + (request.map { ["The request: \($0)"] } ?? []) + ["Its part: \(task)"])
                    .joined(separator: "\n"))
        } else {
            parts.append(
                (["Change the Swift actor `actor \(type)`, with only the standard library."]
                    + (request.map { ["The request: \($0)"] } ?? []) + ["The change: \(task)"]
                    + (failure.map { ["It last failed: \($0)"] } ?? []))
                    .joined(separator: "\n"))
        }
        // How the runtime runs it, one fact to a line.
        parts.append("How the runtime runs it:\n" + runtime.map { "- \($0)" }.joined(separator: "\n"))
        // An idea the code may need, explained before the objects that use it.
        parts += explained
        // The objects that exist: what each is, its methods, and its events.
        if !others.isEmpty { parts.append("Objects that exist:\n" + others.joined(separator: "\n\n")) }
        // The tools it can call, always in scope.
        if !tools.isEmpty { parts.append("Tools it can call, always in scope:\n" + tools.joined(separator: "\n\n")) }
        // The types their values are, which the code uses as they're declared.
        if !values.isEmpty { parts.append("Values they send and take:\n" + values.joined(separator: "\n")) }
        // The code to change, as it is now.
        if let current { parts.append("Its code now:\n\(current)") }
        let ask = parts.joined(separator: "\n\n")
        report?(.asked(ask))
        // A retry builds on the latest answer, which keeps what's right in it, with what was
        // refused in it, each at its code. Only the latest: each try costs the same.
        let question: Transcript.Entry = .prompt(.init(segments: [.text(.init(content: ask))]))
        var entries = [question]
        var problem = "It wrote no code."
        for _ in 0..<attempts {
            let answer = try await respond(entries)
            let wrong = await save(Self.unfenced(answer))
            report?(.answered(answer, wrong.map(Answer.refused) ?? .saved))
            guard let wrong else { return .saved }
            problem = wrong
            let refused = wrong.split(separator: "\n").map { "Refused: \($0)" }.joined(separator: "\n")
            entries = [
                question,
                .response(.init(assetIDs: [], segments: [.text(.init(content: answer))])),
                .prompt(.init(segments: [.text(.init(content: refused))])),
            ]
        }
        return .failed(problem)
    }

    private func respond(_ entries: [Transcript.Entry]) async throws -> String {
        let stream = endpoint.stream(
            request: ModelRequest(input: entries, entries: entries), tools: [], authority: FullAuthority(),
            generating: String.self, purpose: .generation)
        for await event in stream {
            switch event {
            case .generated(let text): return text
            case .failed(let error): throw AgentRuntimeError.modelMisbehavior(String(describing: error))
            default: continue
            }
        }
        throw AgentRuntimeError.modelMisbehavior("The object's writer gave no answer.")
    }

    /// The code without the Markdown fence a chat model wraps it in, which is never Swift.
    static func unfenced(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) else {
            return text
        }
        lines = Array(lines[(start + 1)...])
        if let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            lines = Array(lines[..<end])
        }
        return lines.joined(separator: "\n")
    }
}

/// What happened writing an object, as it happens: what the writer was asked, and each answer, with
/// what came of it.
public enum WriterEvent: Sendable {
    case asked(String)
    case answered(String, Answer)
}

extension WriterEvent {
    /// The event as a log reads it: the question, or an answer with what came of it.
    public var written: String {
        switch self {
        case .asked(let prompt): "=== OBJECT WRITER PROMPT\n\(prompt)\n"
        case .answered(let answer, .saved): "=== OBJECT WRITER ANSWER\n\(answer)\n=== SAVED\n"
        case .answered(let answer, .refused(let why)): "=== OBJECT WRITER ANSWER\n\(answer)\n=== NOT SAVED: \(why)\n"
        }
    }
}

/// What came of one answer: saved, or refused with what's wrong, at its code.
public enum Answer: Sendable, Equatable {
    case saved
    case refused(String)
}

extension AgentHistory.Input {
    /// What was said, as text.
    public var text: String? {
        if case .string(let text) = content.kind { text } else { nil }
    }
}
