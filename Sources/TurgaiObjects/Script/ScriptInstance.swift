import DiscoverableActors
import Foundation
import SwiftScriptSema
import SwiftScriptInterpreter
import Synchronization

/// An object's Swift, running: an instance of its actor, live in an interpreter of its own, as an
/// Erlang process is its module running. What it holds stays in the instance between messages,
/// and the journal keeps a copy, to start it again from. It belongs to the object that runs it
/// and runs on that object's executor: one message at a time runs on it, and messages interleave
/// only where one waits on another object, as a Swift actor's do.
///
/// Another object is a value of the dynamic type `Object`: calling a method on one calls that
/// object, which checks the call when it gets it, and the call returns its reply. Objects are
/// found by the names the code uses, given in messages, or held as data.
public final class ScriptInstance {
    /// Asks the object `recipient` for `request`, and gives back its answer: a call's reply, or
    /// what it publishes.
    public typealias Reaches = (_ recipient: ObjectReference, _ request: ObjectRequest) async throws -> JSONValue

    /// What code asks of another object: to take a message, with its arguments by label (`_0`, `_1`
    /// for unlabeled ones), or what it publishes, by name.
    public enum ObjectRequest: Sendable {
        case call(String, arguments: JSONValue)
        case read(String)
    }

    public let source: Script
    let shape: ObjectShape
    private let object: ScriptObject
    private let host: Host

    private init(source: Script, shape: ObjectShape, object: ScriptObject, host: Host) {
        self.source = source
        self.shape = shape
        self.object = object
        self.host = host
    }

    /// An instance of `source`'s actor, holding `fields` where they're given and its starting
    /// values elsewhere, with its checks holding.
    /// - Parameters:
    ///   - schedules: Told the id of each `Task { … }` its code starts, which its object runs with
    ///     ``runTask(_:)``; `cancels`, of each it cancels.
    public static func start(
        _ source: Script, holding fields: [String: JSONValue] = [:], reaches: @escaping Reaches,
        schedules: @escaping @Sendable (Int) -> Void, cancels: @escaping @Sendable (Int) -> Void
    ) async throws(CodeProblem) -> ScriptInstance {
        let shape = try ObjectShape(source)
        let host = Host(reaches: reaches, schedules: schedules, cancels: cancels)
        do {
            let object = try await ScriptObject(type: source.type, in: ObjectModule.objectFile, of: Self.files(source), module: Uses.module, host: host)
            // What's journaled is as `Codable` writes it: each value reads back as its field's type.
            for field in shape.fields where !field.constant {
                guard let held = fields[field.name] else { continue }
                try object.set(field.name, to: host.portable(held))
            }
            let started = ScriptInstance(source: source, shape: shape, object: object, host: host)
            try await started.check()
            return started
        } catch {
            throw problem(error)
        }
    }

    /// The module `source` is: what it's given, and its own code, as plain Swift.
    static func files(_ source: Script) -> [SwiftCheck.File] {
        ObjectModule(source).files.map { SwiftCheck.File(name: $0.name, code: $0.code) }
    }

    /// What the Swift compiler would refuse in `source` before it runs, every one at its line, as
    /// it lists them, against the module it imports.
    public static func problems(in source: Script) async -> [CodeProblem] {
        let swift = SwiftCheck.problems(in: ObjectModule.objectFile, of: files(source)).map { diagnostic in
            CodeProblem(line: diagnostic.line, span: diagnostic.code, diagnostic.message)
        }
        // And how it uses the runtime's macros, which are Turgai's, as Turgai has them.
        return (swift + RuntimeMacros.problems(in: source)).sorted { ($0.line ?? 0) < ($1.line ?? 0) }
    }

    /// What an object of `source` holds when it's made: each field's starting value, with its
    /// checks holding. It calls no other object to start.
    public static func starts(_ source: Script) async throws(CodeProblem) -> [String: JSONValue] {
        // Its copy is thrown away once it's checked, so a `Task` it starts as it's made never runs:
        // its object runs its own when it lives.
        try await start(
            source,
            reaches: { _, request in
                switch request {
                case .call(let message, _): throw CodeProblem("An object calls no other object as it's made: `\(message)`.")
                case .read(let name): throw CodeProblem("An object reads no other object as it's made: `\(name)`.")
                }
            },
            schedules: { _ in }, cancels: { _ in }
        ).fields()
    }

    /// Runs the `Task { … }` its code started as `id`, and gives back the events it announced.
    public func runTask(_ id: Int) async throws(CodeProblem) -> [Announcement] {
        let run = Run()
        do {
            try await Run.$current.withValue(run) { try await object.runTask(id) }
            try await check()
            return run.announced
        } catch {
            throw Self.problem(error)
        }
    }

    /// What it holds now.
    public func fields() async throws(CodeProblem) -> [String: JSONValue] {
        do {
            var fields: [String: JSONValue] = [:]
            for (name, value) in try object.fields() { fields[name] = try host.json(value) }
            return fields
        } catch {
            throw Self.problem(error)
        }
    }

    /// Handles `message` with `arguments`, by parameter name, label or position: its method runs
    /// on the instance, and its reply comes back with what it printed. Its arguments are checked
    /// against its own typing first, as it's this object that takes them. A message that fails
    /// leaves the instance as it failed: its object starts it again from the journal.
    public func handle(_ name: String, arguments: JSONValue) async throws(CodeProblem) -> ObjectReply {
        guard let message = shape.messages.first(where: { $0.name == name }) else {
            let takes = shape.messages.map(\.written).joined(separator: ", ")
            throw CodeProblem("It takes no `\(name)`; it takes \(takes.isEmpty ? "nothing yet" : takes).")
        }
        let given = arguments.objectValue ?? [:]
        var values: [(label: String?, value: Portable)] = []
        for (index, parameter) in message.parameters.enumerated() {
            guard let argument = given[parameter.name] ?? parameter.label.flatMap({ given[$0] }) ?? given["_\(index)"], argument != .null else {
                throw CodeProblem("`\(message.name)` needs `\(parameter.name)`. It's \(message.written).")
            }
            guard Self.accepts(parameter.kind, argument) else {
                throw CodeProblem("`\(parameter.name)` is `\(argument.inline)`, but `\(message.name)` takes \(parameter.kind.written) there.")
            }
            values.append((parameter.label, host.portable(argument)))
        }
        let run = Run()
        do {
            let reply = try await Run.$current.withValue(run) { try await object.call(message.name, arguments: values) }
            try await check()
            return ObjectReply(
                reply: message.reply == nil ? .null : try host.json(reply), printed: run.printed, announced: run.announced)
        } catch {
            throw Self.problem(error)
        }
    }

    // MARK: Running

    /// What a message's code, or a task's, did besides its reply: what it printed, line by line,
    /// and the events it announced. Each has its own, even while another waits.
    fileprivate final class Run: Sendable {
        @TaskLocal static var current: Run?
        private let written = Mutex<[String]>([])
        private let announcements = Mutex<[Announcement]>([])

        func print(_ text: String) {
            written.withLock { $0 += text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
        }

        func announce(_ announcement: Announcement) {
            announcements.withLock { $0.append(announcement) }
        }

        var printed: [String] { written.withLock { $0 } }
        var announced: [Announcement] { announcements.withLock { $0 } }
    }

    /// Its checks, after it's made and after each message.
    private func check() async throws {
        guard shape.checks else { return }
        if case .string(let failed) = try await object.call("_check", arguments: []), !failed.isEmpty {
            throw CodeProblem("It would break `\(failed)`.")
        }
    }

    private static func problem(_ error: any Error) -> CodeProblem {
        switch error {
        case let problem as CodeProblem: return problem
        case let problems as ScriptObject.Problems:
            let first = problems.diagnostics.first
            return CodeProblem(line: first?.line, first?.message ?? "\(problems)")
        case let trap as Trap: return CodeProblem(line: trap.line, trap.message)
        case let thrown as Thrown: return CodeProblem("It threw `\(thrown.type)`: \(thrown.value)")
        default: return CodeProblem("\(error)")
        }
    }

    /// What the code reaches outside itself, as Turgai has it: other objects by message, made
    /// ones as virtual actors, named ones by name, and the runtime's announcing.
    private final class Host: ScriptHost {
        let itself = ObjectHandle("itself")
        private let reaches: Reaches
        private let schedules: @Sendable (Int) -> Void
        private let cancels: @Sendable (Int) -> Void
        /// The objects the code holds, by the handle it holds each as.
        private var references: [(handle: ObjectHandle, reference: ObjectReference)] = []

        init(reaches: @escaping Reaches, schedules: @escaping @Sendable (Int) -> Void, cancels: @escaping @Sendable (Int) -> Void) {
            self.reaches = reaches
            self.schedules = schedules
            self.cancels = cancels
        }

        func send(_ message: String, to object: ObjectHandle, arguments: [(label: String?, value: Portable)]) async throws -> Portable {
            var members: [String: JSONValue] = [:]
            for (index, argument) in arguments.enumerated() { members[argument.label ?? "_\(index)"] = try json(argument.value) }
            return portable(try await reaches(try reference(object), .call(message, arguments: .object(members))))
        }

        func read(_ property: String, of object: ObjectHandle) async throws -> Portable {
            portable(try await reaches(try reference(object), .read(property)))
        }

        /// Another object's type, made with `Type()`: the object whose id is the type's name, made
        /// when it's first called if there's none yet.
        func make(_ type: String) async throws -> ObjectHandle {
            handle(for: .virtual(id: type, type: type))
        }

        /// The objects the code reaches by name.
        func global(_ name: String) async throws -> Portable {
            .reference(handle(for: .named(name)))
        }

        func call(_ function: String, arguments: [(label: String?, value: Portable)]) async throws -> Portable {
            guard function == RuntimeMacros.announce, arguments.count == 2, case .string(let event) = arguments[0].value else {
                throw CodeProblem("`\(function)` isn't the runtime's.")
            }
            Run.current?.announce(Announcement(event: event, values: try json(arguments[1].value)))
            return .null
        }

        func schedule(task id: Int) { schedules(id) }
        func cancel(task id: Int) { cancels(id) }
        func print(_ text: String) { Run.current?.print(text) }

        // MARK: Values

        func handle(for reference: ObjectReference) -> ObjectHandle {
            if reference == .itself { return itself }
            if let known = references.first(where: { $0.reference == reference }) { return known.handle }
            let handle = ObjectHandle("\(references.count + 1)")
            references.append((handle, reference))
            return handle
        }

        func reference(_ handle: ObjectHandle) throws -> ObjectReference {
            if handle == itself { return .itself }
            guard let reference = references.first(where: { $0.handle == handle })?.reference else {
                throw CodeProblem("An object the code holds isn't known.")
            }
            return reference
        }

        /// JSON as it crosses into the code, an object's reference as the object.
        func portable(_ json: JSONValue) -> Portable {
            if let reference = ObjectReference(json) { return .reference(handle(for: reference)) }
            switch json {
            case .null: return .null
            case .bool(let flag): return .bool(flag)
            case .integer(let number): return .int(Int(number))
            case .unsignedInteger(let number): return .int(Int(number))
            case .number(let number): return .double(number)
            case .string(let text): return .string(text)
            case .array(let items): return .array(items.map(portable))
            case .object(let members): return .object(members.sorted { $0.key < $1.key }.map { ($0.key, portable($0.value)) })
            }
        }

        func json(_ portable: Portable) throws -> JSONValue {
            switch portable {
            case .null: return .null
            case .bool(let flag): return .bool(flag)
            case .int(let number): return .integer(Int64(number))
            case .double(let number): return .number(number)
            case .string(let text): return .string(text)
            case .array(let items): return .array(try items.map(json))
            case .object(let members):
                var object: [String: JSONValue] = [:]
                for (key, value) in members { object[key] = try json(value) }
                return .object(object)
            case .reference(let handle): return try reference(handle).json
            }
        }
    }

    // MARK: Values

    /// Whether a value given for a parameter is of its kind: checked on every message, by the
    /// object taking it.
    static func accepts(_ kind: ValueKind, _ value: JSONValue) -> Bool {
        switch (kind, value) {
        case (.int, .integer), (.int, .unsignedInteger), (.double, .number), (.double, .integer), (.double, .unsignedInteger),
            (.string, .string), (.bool, .bool):
            true
        case (.int, .number(let number)): number.rounded() == number
        case (.list(let element), .array(let items)): items.allSatisfy { accepts(element, $0) }
        case (.map(let element), .object(let members)) where ObjectReference(value) == nil: members.values.allSatisfy { accepts(element, $0) }
        case (.object, _): ObjectReference(value) != nil
        case (.other, _): true
        default: false
        }
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let members) = self { members } else { nil }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let items) = self { items } else { nil }
    }

    var stringValue: String? {
        if case .string(let text) = self { text } else { nil }
    }
}
