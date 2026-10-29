import DiscoverableActors
import Doppel
import DoppelRuntime
import Foundation
import ScopedEffect
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

    /// The object of `type` with `id`, which the code named with `Type(id:)`: the reference to
    /// it, which is made if it isn't there yet.
    public typealias Makes = (_ type: ObjectTypeName, _ id: ObjectIdentity) async throws -> ObjectReference

    /// Runs the tool function the code called, `Tools.Http.send`, with the value it gave, and gives
    /// back the value it answered.
    public typealias CallsTool = (_ function: ToolFunctionName, _ input: JSONValue) async throws -> JSONValue

    /// What code asks of another object: to take a message, with its arguments by label (`_0`, `_1`
    /// for unlabeled ones), through the type the code holds it as (`nil` for any object), or what
    /// it publishes, by name.
    public enum ObjectRequest: Sendable {
        case call(String, arguments: JSONValue, through: String?)
        case read(String)
    }

    public let source: Script
    let shape: ObjectShape
    private let object: LiveActor
    private let host: Host

    private init(source: Script, shape: ObjectShape, object: LiveActor, host: Host) {
        self.source = source
        self.shape = shape
        self.object = object
        self.host = host
    }

    /// An instance of `source`'s actor, holding `fields` where they're given and its starting
    /// values elsewhere, with its checks holding. It's made with its `init()`, as a Swift actor is
    /// each time it starts; building it makes no object, since what it holds is its object's: what
    /// its `init()` makes is `unmade` until its object makes it. From then on, `makes` makes them.
    /// - Parameters:
    ///   - schedules: Told the id of each `Task { … }` its code starts, which its object runs with
    ///     ``runTask(_:)``; `cancels`, of each it cancels.
    public static func start(
        _ source: Script, as identity: ObjectIdentity, holding fields: [String: JSONValue] = [:],
        reaches: @escaping Reaches,
        makes: @escaping Makes, tools: @escaping CallsTool, schedules: @escaping @Sendable (Int) -> Void,
        cancels: @escaping @Sendable (Int) -> Void
    ) async throws(CodeProblem) -> ScriptInstance {
        let shape = try ObjectShape(source)
        let host = Host(source, reaches: reaches, makes: makes, tools: tools, schedules: schedules, cancels: cancels)
        do {
            // Made as every object is, with its id.
            let object = try await LiveActor(
                type: source.type, in: ObjectModule.objectFile, of: Self.files(source), module: Uses.module,
                arguments: [(ObjectModule.idLabel, .string(identity.rawValue))], host: host)
            host.built()
            // What's journaled is as `Codable` writes it: each value reads back as its field's type.
            // A constant is its `init()`'s, except an object it holds, which is its object's.
            for field in shape.fields {
                guard let held = fields[field.name], !field.constant || !ObjectReference.all(in: held).isEmpty else {
                    continue
                }
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
        // How its stored properties get their values comes first: the rest of its Swift is
        // checked as an object made with its id.
        let starting = StartingValues.problems(in: source.code, type: source.type)
        guard starting.isEmpty else { return starting.sorted { ($0.line ?? 0) < ($1.line ?? 0) } }
        let swift = SwiftCheck.problems(in: ObjectModule.objectFile, of: files(source)).map { diagnostic in
            CodeProblem(line: diagnostic.line, span: diagnostic.code, diagnostic.message)
        }
        // And how it uses the runtime's macros, which are Turgai's, as Turgai has them, the
        // objects it names, which exist, and what it sends and keeps, which the runtime keeps as data.
        var problems = swift + RuntimeMacros.problems(in: source) + ExistingObjects.problems(in: source)
        if swift.isEmpty,
            let declarations = SwiftCheck.declarations(of: source.type, in: ObjectModule.objectFile, of: files(source))
                .declarations
        {
            problems += CodableValues.problems(
                in: source.code, type: source.type, declarations: declarations, lasting: source.lasting)
        }
        return problems.sorted { ($0.line ?? 0) < ($1.line ?? 0) }
    }

    /// What an object of `source` holds when it starts: each field's starting value, with its
    /// checks holding. It calls no other object to start, and the objects its `init()` makes are
    /// `unmade`: its copy is thrown away once it's checked.
    public static func starts(_ source: Script, as identity: ObjectIdentity) async throws(CodeProblem) -> [String:
        JSONValue]
    {
        // A `Task` it starts as it's made never runs: its object runs its own when it lives.
        try await start(
            source, as: identity,
            reaches: { _, request in
                switch request {
                case .call(let message, _, _):
                    throw CodeProblem("An object calls no other object as it's made: `\(message)`.")
                case .read(let name): throw CodeProblem("An object reads no other object as it's made: `\(name)`.")
                }
            },
            makes: { type, _ in throw CodeProblem("An object reaches no `\(type)` before it starts.") },
            tools: { function, _ in throw CodeProblem("An object calls no tool as it's made: `\(function)`.") },
            schedules: { _ in }, cancels: { _ in }
        ).fields()
    }

    /// Runs the `Task { … }` its code started as `id`, and gives back the events it announced.
    /// A refusal of what its scope didn't allow comes back as itself: it isn't its code's problem.
    public func runTask(_ id: Int) async throws -> [Announcement] {
        let run = Run()
        do {
            try await Run.$current.withValue(run) { try await object.runTask(id) }
            try await check()
            return run.announced
        } catch {
            throw Self.passed(error)
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
    /// on the instance, and its reply comes back with what it printed. Its arguments are read as
    /// their types, and what isn't of its type is refused with where it is in the value. A message
    /// that fails leaves the instance as it failed: its object starts it again from the journal. A
    /// refusal of what its scope didn't allow comes back as itself: it isn't its code's problem.
    public func handle(_ name: String, arguments: JSONValue) async throws -> ObjectReply {
        let given = arguments.objectValue ?? [:]
        guard let message = shape.message(name, given: given) else {
            let named = shape.messages.filter { $0.name == ActionKeys.baseName(of: name) }
            if !named.isEmpty {
                throw CodeProblem(
                    "`\(name)` is called with what one of these takes: "
                        + named.map(\.written).joined(separator: ", ") + ".")
            }
            let takes = shape.messages.map(\.written).joined(separator: ", ")
            throw CodeProblem("It takes no `\(name)`; it takes \(takes.isEmpty ? "nothing yet" : takes).")
        }
        var values: [(label: String?, value: Portable)] = []
        for (index, parameter) in message.parameters.enumerated() {
            guard let argument = given[parameter.name] ?? parameter.label.flatMap({ given[$0] }) ?? given["_\(index)"],
                argument != .null
            else {
                throw CodeProblem("`\(message.name)` needs `\(parameter.name)`. It's \(message.written).")
            }
            values.append((parameter.label, host.portable(argument)))
        }
        let run = Run()
        do {
            let reply = try await Run.$current.withValue(run) { try await object.call(message.name, arguments: values) }
            try await check()
            return ObjectReply(
                reply: message.replyType == nil ? .null : try host.json(reply), printed: run.printed,
                announced: run.announced)
        } catch {
            throw Self.passed(error)
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

    /// A refusal as itself, and anything else as its code's problem.
    private static func passed(_ error: any Error) -> any Error {
        error as? EffectDenied ?? problem(error)
    }

    private static func problem(_ error: any Error) -> CodeProblem {
        switch error {
        case let problem as CodeProblem: return problem
        case let problems as LiveActor.Problems:
            let first = problems.diagnostics.first
            return CodeProblem(line: first?.line, first?.message ?? "\(problems)")
        case let trap as Trap: return CodeProblem(line: trap.line, trap.message)
        case let thrown as Thrown: return CodeProblem("It threw `\(thrown.type)`: \(thrown.value)")
        default: return CodeProblem("\(error)")
        }
    }

    /// What the code reaches outside itself, as Turgai has it: other objects by message, made
    /// ones as virtual actors, and the runtime's announcing.
    private final class Host: ActorHost {
        /// The object itself, of its own type.
        let itself: ObjectHandle
        private let reaches: Reaches
        private let makes: Makes
        private let tools: CallsTool
        /// Whether its `init()` is running: what it makes then is its object's to make.
        private var building = true
        private let schedules: @Sendable (Int) -> Void
        private let cancels: @Sendable (Int) -> Void
        /// The objects the code holds, by the handle it holds each as.
        private var references: [(handle: ObjectHandle, reference: ObjectReference)] = []

        init(
            _ source: Script, reaches: @escaping Reaches, makes: @escaping Makes, tools: @escaping CallsTool,
            schedules: @escaping @Sendable (Int) -> Void, cancels: @escaping @Sendable (Int) -> Void
        ) {
            itself = ObjectHandle("itself", type: source.type)
            self.reaches = reaches
            self.makes = makes
            self.tools = tools
            self.schedules = schedules
            self.cancels = cancels
        }

        func send(
            _ message: String, to object: ObjectHandle, through type: String?,
            arguments: [(label: String?, value: Portable)]
        ) async throws -> Portable {
            var members: [String: JSONValue] = [:]
            for (index, argument) in arguments.enumerated() {
                members[argument.label ?? "_\(index)"] = try json(argument.value)
            }
            return portable(
                try await reaches(try reference(object), .call(message, arguments: .object(members), through: type)))
        }

        func read(_ property: String, of object: ObjectHandle) async throws -> Portable {
            portable(try await reaches(try reference(object), .read(property)))
        }

        /// The object of another object's type with `id`, named with `Type(id:)`: `unmade` while
        /// it's built.
        func make(_ type: String, arguments: [(label: String?, value: Portable)]) async throws -> ObjectHandle {
            guard let given = arguments.first(where: { $0.label == ObjectModule.idLabel }),
                case .string(let written) = given.value
            else {
                throw CodeProblem("`\(type)` is named by its id: `\(type)(id:)`.")
            }
            // As code writes them, crossing into the runtime: the type's name, and the id as ids are kept.
            let made = ObjectTypeName(rawValue: type)
            let id = ObjectIdentity(rawValue: ObjectNames.handle(for: written))
            return handle(for: building ? .unmade(type: made, id: id) : try await makes(made, id))
        }

        /// Its `init()` has run: what it makes from now on, it makes.
        func built() {
            building = false
        }

        func call(_ function: String, arguments: [(label: String?, value: Portable)]) async throws -> Portable {
            // A tool's function, which the node runs: `Tools.Http.send`, with the one value it takes.
            if let tool = ToolFunctionName(qualified: function) {
                guard let input = arguments.first?.value, arguments.count == 1 else {
                    throw CodeProblem("`\(function)` takes one value.")
                }
                return portable(try await tools(tool, try json(input)))
            }
            guard function == RuntimeMacros.announce, arguments.count == 2, case .string(let event) = arguments[0].value
            else {
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
            // It goes into the code with its type, which is checked wherever the code takes an
            // object of a type.
            let handle = ObjectHandle("\(references.count + 1)", type: reference.type)
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
            case .object(let members):
                return .object(members.sorted { $0.key < $1.key }.map { ($0.key, portable($0.value)) })
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
