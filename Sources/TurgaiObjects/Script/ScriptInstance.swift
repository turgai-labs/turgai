import DiscoverableActors
import Foundation
import SwiftParser
import SwiftScriptInterpreter
import SwiftSyntax
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
    private let interpreter: Interpreter
    private let instance: Value

    private init(source: Script, shape: ObjectShape, interpreter: Interpreter, instance: Value) {
        self.source = source
        self.shape = shape
        self.interpreter = interpreter
        self.instance = instance
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
        let interpreter = Interpreter(
            output: { text in Run.current?.print(text) },
            error: { _ in })
        interpreter.schedulesTask = schedules
        interpreter.cancelsTask = cancels
        // What crosses to other objects is as `Codable` writes it, and what comes back is read as
        // the type its object declares it.
        let bridge = ValueBridge(interpreter: interpreter)
        // Another object, asked: a call or a read goes to it as a message, and its answer is read
        // as its type declares it, or as it reads when its type isn't known here.
        let reach: (Value, DynamicAccess) async throws -> Value = { receiver, access in
            guard case .opaque(let type, let recipient as ObjectReference) = receiver else { return .void }
            let member: String
            let answer: JSONValue
            switch access {
            case .call(let message, let labels, let values):
                var arguments: [String: JSONValue] = [:]
                for (index, (label, value)) in zip(labels, values).enumerated() {
                    arguments[label ?? "_\(index)"] = try bridge.json(of: value)
                }
                member = message
                answer = try await reaches(recipient, .call(message, arguments: .object(arguments)))
            case .read(let name):
                member = name
                answer = try await reaches(recipient, .read(name))
            }
            guard let declared = interpreter.importedActor(type)?.answers[member] else { return value(of: answer) }
            do {
                return try bridge.value(of: answer, as: declared)
            } catch {
                throw CodeProblem("`\(member)` answered `\(answer.inline)`, which isn't a `\(declared.trimmedDescription)`: \(error)")
            }
        }
        // An object whose type isn't declared here, such as one its code makes on its first call:
        // asked by name, its answers read as they are.
        interpreter.registerDynamicType("Object", handler: reach)
        // What an `@Event` method's body calls: the event, with its values, announced by the
        // message or task running now.
        interpreter.rootScope.bind(
            RuntimeMacros.announce,
            value: .function(Function(name: RuntimeMacros.announce, parameters: [], kind: .builtin { arguments in
                guard arguments.count == 2, case .string(let event) = arguments[0] else { return .void }
                let values = try bridge.json(of: arguments[1])
                Run.current?.announce(Announcement(event: event, values: values))
                return .void
            })),
            mutable: false)
        do {
            // The other objects and their values, as the module its code imports.
            try await interpreter.import(source.uses.interface, events: [RuntimeMacros.event], host: reach)
            // The objects its code reaches by name, each as its type, when it's declared: those it
            // was written against, wherever the code names them, and those it calls that weren't.
            for name in Set(source.uses.names.keys).union(source.namedObjects) {
                let type = source.uses.names[name].flatMap { interpreter.importedActor($0)?.name } ?? "Object"
                interpreter.rootScope.bind(name, value: .opaque(typeName: type, value: ObjectReference.named(name)), mutable: false)
            }
            // Another object's type, made with `Type()`: the object whose id is the type's name, made
            // when it's first called if there's none yet.
            for type in source.madeTypes {
                let declared = interpreter.importedActor(type) != nil
                // A type of the interpreter's own isn't another object.
                if !declared, await interpreter.provides(type) { continue }
                // Its object's id is the type's name: the one way code makes an object, for now.
                let reference = ObjectReference.virtual(id: type, type: type)
                let typed = declared ? type : "Object"
                interpreter.rootScope.bind(
                    type,
                    value: .function(Function(name: type, parameters: [], kind: .builtin { _ in .opaque(typeName: typed, value: reference) })),
                    mutable: false)
            }
            // What runs is the code with the runtime's macros expanded.
            try await interpreter.eval(source.expanded)
            let instance = try await interpreter.make(source.type)
            // What's journaled is as `Codable` writes it: each value reads back as its field's
            // type, as `Codable` decodes a property, the type written or its starting value's.
            for field in shape.fields where !field.constant {
                guard let held = fields[field.name] else { continue }
                let starting = try await interpreter.property(field.name, of: instance)
                if let type = field.type.map({ TypeSyntax(stringLiteral: $0) }) ?? Self.type(of: starting) {
                    try await interpreter.set(field.name, of: instance, to: try bridge.value(of: held, as: type))
                } else {
                    try await interpreter.set(field.name, of: instance, to: bridge.typed(value(of: held, as: field.kind ?? Self.kind(of: starting))))
                }
            }
            let started = ScriptInstance(source: source, shape: shape, interpreter: interpreter, instance: instance)
            try await started.check()
            return started
        } catch {
            throw problem(error, interpreter)
        }
    }

    /// What the Swift compiler would refuse in `source` before it runs, every one at its line, as
    /// it lists them, against the module it imports.
    public static func problems(in source: Script) async -> [CodeProblem] {
        let interpreter = Interpreter(output: { _ in }, error: { _ in })
        let diagnostics = await interpreter.check(
            source.code, importing: [source.uses.interface], names: source.uses.names, handler: DynamicObject.handler(for:),
            bodiesFrom: [RuntimeMacros.event], followedBy: [RuntimeMacros.subscribed])
        return diagnostics.map { diagnostic in
            CodeProblem(
                line: diagnostic.line, span: diagnostic.code, diagnostic.message,
                phrasing: diagnostic.phrasing == .statement ? .statement : .reason)
        }
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
            try await Run.$current.withValue(run) { try await interpreter.runTask(id) }
            try await check()
            return run.announced
        } catch {
            throw Self.problem(error, interpreter)
        }
    }

    /// What it holds now.
    public func fields() async throws(CodeProblem) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        do {
            for field in shape.fields {
                let value = try await interpreter.property(field.name, of: instance)
                fields[field.name] = try ValueBridge(interpreter: interpreter).json(of: value)
            }
        } catch {
            throw Self.problem(error, interpreter)
        }
        return fields
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
        var values: [Value] = []
        for (index, parameter) in message.parameters.enumerated() {
            guard let argument = given[parameter.name] ?? parameter.label.flatMap({ given[$0] }) ?? given["_\(index)"], argument != .null else {
                throw CodeProblem("`\(message.name)` needs `\(parameter.name)`. It's \(message.written).")
            }
            guard Self.accepts(parameter.kind, argument) else {
                throw CodeProblem("`\(parameter.name)` is `\(argument.inline)`, but `\(message.name)` takes \(parameter.kind.written) there.")
            }
            // Read as the type it's declared, as `Codable` reads it.
            do {
                values.append(try ValueBridge(interpreter: interpreter).value(of: argument, as: TypeSyntax(stringLiteral: parameter.type)))
            } catch {
                throw CodeProblem("`\(parameter.name)` is `\(argument.inline)`, which isn't a `\(parameter.type)`: \(error)")
            }
        }
        let run = Run()
        do {
            let reply = try await Run.$current.withValue(run) {
                try await interpreter.call(message.name, on: instance, arguments: values)
            }
            try await check()
            return ObjectReply(
                reply: message.reply == nil ? .null : try written(reply, "its reply"), printed: run.printed, announced: run.announced)
        } catch {
            throw Self.problem(error, interpreter)
        }
    }

    // MARK: The interpreter

    /// What a message's code, or a task's, did besides its reply: what it printed, line by line,
    /// the object's own account of what it did, and the events it announced. Each has its own,
    /// even while another waits.
    private final class Run: Sendable {
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
        if case .string(let failed) = try await interpreter.call("_check", on: instance, arguments: []), !failed.isEmpty {
            throw CodeProblem("It would break `\(failed)`.")
        }
    }

    private static func problem(_ error: Error, _ interpreter: Interpreter) -> CodeProblem {
        if let problem = error as? CodeProblem { return problem }
        if let parse = error as? ParseError, let first = parse.diagnostics.first {
            return CodeProblem(line: first.line, first.message)
        }
        let rendered = interpreter.renderRuntimeError(error)
        let first = rendered.split(separator: "\n").first.map(String.init) ?? "\(error)"
        // The interpreter's `<input>:22:13: error: …`, read as the line it's at and what's wrong.
        let parts = first.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        if parts.count == 5, parts[0] == "<input>", let line = Int(parts[1]), parts[3].trimmingCharacters(in: .whitespaces) == "error" {
            return CodeProblem(line: line, parts[4].trimmingCharacters(in: .whitespaces))
        }
        // An error its code caught and rethrew, as the interpreter writes it: `error: …`.
        return CodeProblem(first.hasPrefix("error: ") ? String(first.dropFirst("error: ".count)) : first)
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

    /// `value` as `Codable` writes it, for another object or the journal.
    private func written(_ value: Value, _ name: String) throws(CodeProblem) -> JSONValue {
        try ValueBridge(interpreter: interpreter).json(of: value)
    }

    /// Why `value` can't go to another object: it isn't data.
    static func notData(_ value: Value, _ name: String) -> CodeProblem {
        CodeProblem("\(name) is a \(SwiftScriptInterpreter.typeName(value)), which can't go to another object: data is numbers, text, true or false, objects, and the lists, dictionaries, structs and enums of them.")
    }

    /// Plain data the interpreter made, and objects, as JSON: numbers, text, true or false, and
    /// the lists and dictionaries of them, with each object its reference. Structs and enums are
    /// written by ``ValueBridge``, as `Codable` writes them.
    static func json(_ value: Value, _ name: String) throws(CodeProblem) -> JSONValue {
        func convert(_ value: Value) throws(CodeProblem) -> JSONValue? {
            switch value {
            case .int(let int): return .integer(Int64(int))
            case .double(let double): return .number(double)
            case .string(let string): return .string(string)
            case .bool(let bool): return .bool(bool)
            case .void, .optional(.none): return .null
            case .optional(.some(let inner)): return try convert(inner)
            case .array(let items), .set(let items):
                var converted: [JSONValue] = []
                for item in items {
                    guard let written = try convert(item) else { return nil }
                    converted.append(written)
                }
                return .array(converted)
            case .dict(let entries):
                var members: [String: JSONValue] = [:]
                for entry in entries {
                    guard let key = try convert(entry.key), let value = try convert(entry.value) else { return nil }
                    members[key.inline] = value
                }
                return .object(members)
            // Another object, of any type, or itself passed on: its reference.
            case .opaque(_, let reference as ObjectReference): return try written(reference)
            case .classInstance: return try written(.itself)
            default: return nil
            }
        }
        guard let converted = try convert(value) else { throw notData(value, name) }
        return converted
    }

    /// An object's reference, as it's written.
    private static func written(_ reference: ObjectReference) throws(CodeProblem) -> JSONValue {
        do {
            return try reference.json
        } catch {
            throw CodeProblem("An object's reference can't be written: \(error)")
        }
    }

    /// The type of a value the interpreter made, as Swift infers a property's from its starting
    /// value: `nil` where it can't tell, such as an empty array's.
    static func type(of value: Value) -> TypeSyntax? {
        switch value {
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .bool: "Bool"
        case .structValue(let type, _), .enumValue(let type, _, _): TypeSyntax(stringLiteral: type)
        case .array(let items): items.first.flatMap(type(of:)).map { "[\($0)]" }
        default: nil
        }
    }

    /// The kind of a value the interpreter made, as far as it tells: a field's starting value,
    /// when its type isn't written.
    static func kind(of value: Value) -> ValueKind? {
        switch value {
        case .int: .int
        case .double: .double
        case .string: .string
        case .bool: .bool
        case .optional(let wrapped?): kind(of: wrapped)
        case .array(let items): items.first.flatMap(kind(of:)).map(ValueKind.list)
        case .opaque("Object", _): .object
        default: nil
        }
    }

    /// A journaled value as the interpreter holds it, as `kind` when that's known.
    static func value(of json: JSONValue, as kind: ValueKind? = nil) -> Value {
        if let reference = ObjectReference(json) { return .opaque(typeName: "Object", value: reference) }
        switch (json, kind) {
        case (.null, _): return .optional(nil)
        case (.bool(let bool), _): return .bool(bool)
        case (.integer(let integer), .double?): return .double(Double(integer))
        case (.unsignedInteger(let integer), .double?): return .double(Double(integer))
        case (.number(let number), .int?): return .int(Int(number))
        case (.integer(let integer), _): return .int(Int(integer))
        case (.unsignedInteger(let integer), _): return .int(Int(integer))
        case (.number(let number), _): return .double(number)
        case (.string(let string), _): return .string(string)
        case (.array(let items), .list(let element)?): return .array(items.map { value(of: $0, as: element) })
        case (.array(let items), _): return .array(items.map { value(of: $0) })
        case (.object(let members), _):
            let element: ValueKind? = if case .map(let element)? = kind { element } else { nil }
            return .dict(members.sorted { $0.key < $1.key }.map { DictEntry(key: .string($0.key), value: value(of: $0.value, as: element)) })
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
