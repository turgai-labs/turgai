import DiscoverableActors
import Foundation

extension Behavior {
    /// Reads a behavior named `name` from its spec and links it: everything that can be checked
    /// without other objects running. Names and types, and that each send to an object it knows
    /// is a message that object takes. Errors name the part of the spec, such as
    /// `receive[0].actions[1]`.
    /// - Parameter objects: What each object it can refer to takes, by name: an object's type is
    ///   its behavior. A reference to an object not here is checked when a message reaches it.
    public init(name: String, written: Written, objects: [String: MessageProtocol] = [:]) throws(BehaviorError) {

        var fields: [String: Field] = [:]
        for field in written.fields {
            try Signature.checkName(field.name, what: "field")
            guard fields[field.name] == nil else { throw BehaviorError("The data `\(field.name)` is there twice.") }
            fields[field.name] = try Field(start: field.start, at: "`\(field.name)`'s start")
        }

        var clauses: [Clause] = []
        for clause in written.receive {
            var reader = Reader(fields: fields, objects: objects)
            // Named in the words a model making it uses: the event, and its condition if it has one.
            let condition = (clause.when ?? []).map { Behavior.written($0) }.joined(separator: " and ")
            clauses.append(try reader.clause(clause, at: "The event `\(clause.on)`" + (condition.isEmpty ? "" : " (if \(condition))")))
        }
        for clause in clauses {
            if let first = clauses.first(where: { $0.message.name == clause.message.name }),
                first.message.parameters != clause.message.parameters
            {
                throw BehaviorError(
                    "`\(clause.message.name)` has different parameters in different clauses. Give them the same in each: `\(first.message.written)`.")
            }
        }

        self.init(name: name, source: written, fields: fields, clauses: try Self.typingReplies(of: clauses, fields: fields))
        try link(objects: objects)
    }

}

extension Behavior {
    /// The clauses with each message's reply type: what its clauses reply. They reply alike: all
    /// of them or none, and the same type.
    static func typingReplies(of clauses: [Clause], fields: [String: Field]) throws(BehaviorError) -> [Clause] {
        var replies: [String: ValueType] = [:]
        for message in clauses.map(\.message.name).reduce(into: [String](), { if !$0.contains($1) { $0.append($1) } }) {
            let handling = clauses.filter { $0.message.name == message }
            // A rejecting clause has no successful result to type. Successful clauses either all
            // reply, or none do, and their replies have one compatible type.
            let successful = handling.filter { clause in
                !clause.actions.contains { if case .reject = $0 { true } else { false } }
            }
            let replied = successful.map { clause in
                clause.actions.lazy.compactMap { action -> Value? in if case .reply(let value) = action { value } else { nil } }.last
            }
            let replying = replied.compactMap { $0 }.count
            guard replying == 0 || replying == successful.count else {
                throw BehaviorError("`\(message)` replies in one clause and not in another. Reply in every clause for it, or in none.")
            }
            var type: ValueType?
            for (clause, value) in zip(successful, replied) {
                guard let value, let new = replyType(of: value, in: clause, fields: fields) else { continue }
                guard let known = type, known != new else {
                    type = new
                    continue
                }
                guard let merged = merged(known, new) else {
                    throw BehaviorError(
                        "`\(message)` replies \(known.withArticle) in one clause and \(new.withArticle) in another. Reply the same kind of value in each.")
                }
                type = merged
            }
            replies[message] = type
        }
        return clauses.map { clause in
            let message = clause.message
            return Clause(
                message: Signature(name: message.name, parameters: message.parameters, reply: replies[message.name]),
                guards: clause.guards, actions: clause.actions)
        }
    }

    /// What a reply is, as far as it's known before it runs.
    private static func replyType(of value: Value, in clause: Clause, fields: [String: Field]) -> ValueType? {
        switch value {
        case .literal(let json): ValueType(of: json)
        case .parameter(let name): clause.message.parameters.first { $0.name == name }?.type
        case .field(let name): fields[name]?.type
        case .me: .object
        case .text: .string
        }
    }

    /// Two reply types that are one: an integer is a number.
    private static func merged(_ a: ValueType, _ b: ValueType) -> ValueType? {
        switch (a, b) {
        case (.integer, .number), (.number, .integer): .number
        case (.like, .object), (.object, .like), (.like, .like): .object
        default: nil
        }
    }
}

extension Behavior.Field {
    /// A field's starting value as written: a value, or another object by its handle.
    init(start: Behavior.Written.Value, at path: String) throws(BehaviorError) {
        switch start {
        case .object(let handle): self = .object(handle)
        case .number(let number): self = .value(Behavior.literal(number))
        case .text(let text): self = .value(.string(text))
        case .boolean(let boolean): self = .value(.bool(boolean))
        case .list(let items): self = .value(.array(items.map(JSONValue.string)))
        case .name(let name):
            throw BehaviorError(
                "\(path) is the name `\(name)`, but a starting value is a number, text, true or false, a list, or an object by its handle.")
        }
    }

    /// A value as written, as a field named `name` holds it, such as `20` for `limit`.
    public static func value(_ written: Behavior.Written.Value, of name: String) throws(BehaviorError) -> JSONValue {
        try Behavior.Field(start: written, at: "`\(name)`").initial
    }

    /// Start values given as fields, such as `limit` starting at 20, for an object that starts
    /// with values of its own.
    public static func values(_ fields: [Behavior.Written.Field]) throws(BehaviorError) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for field in fields {
            values[field.name] = try Behavior.Field(start: field.start, at: "`\(field.name)`'s start").initial
        }
        return values
    }
}

extension Behavior {
    /// A number as written: whole numbers are integers, so they count and compare as such.
    static func literal(_ number: Double) -> JSONValue {
        number.rounded() == number && abs(number) < 1e15 ? .integer(Int64(number)) : .number(number)
    }
}

/// Reads one clause, knowing the behavior's fields and protocols, and the clause's parameters
/// once read.
private struct Reader {
    let fields: [String: Behavior.Field]
    let objects: [String: MessageProtocol]
    var parameters: [Parameter] = []

    init(fields: [String: Behavior.Field], objects: [String: MessageProtocol]) {
        self.fields = fields
        self.objects = objects
    }

    mutating func clause(_ written: Behavior.Written.Clause, at path: String) throws(BehaviorError) -> Behavior.Clause {
        let message = try self.message(written, at: path)
        parameters = message.parameters
        let path = "\(path) (`\(message.name)`)"
        var guards: [Behavior.Guard] = []
        for written in written.when ?? [] {
            guards.append(try guarded(written, at: "\(path), in its condition,"))
        }
        var actions: [Behavior.Action] = []
        for (index, action) in written.actions.enumerated() {
            actions.append(try self.action(action, at: "\(path), step \(index + 1),"))
        }
        return Behavior.Clause(message: message, guards: guards, actions: actions)
    }

    /// The message a clause handles, with its parameters.
    private func message(_ written: Behavior.Written.Clause, at path: String) throws(BehaviorError) -> Signature {
        try Signature.checkName(written.on, what: "message")
        var parameters: [Parameter] = []
        for parameter in written.parameters ?? [] {
            try Signature.checkName(parameter.name, what: "parameter")
            guard !parameters.contains(where: { $0.name == parameter.name }) else {
                throw BehaviorError("\(path) is given `\(parameter.name)` twice.")
            }
            parameters.append(
                Parameter(name: parameter.name, type: try ValueType(parameter, at: "\(path), its value `\(parameter.name)`,")))
        }
        return Signature(name: written.on, parameters: parameters)
    }

    // MARK: Guards

    func guarded(_ written: Behavior.Written.Guard, at path: String) throws(BehaviorError) -> Behavior.Guard {
        let left = try value(written.left, at: path)
        let comparison = Behavior.Comparison(written.comparison)
        switch written.comparison {
        case .isEmpty, .isNotEmpty:
            try checkList(left, at: path, doing: comparison.rawValue)
            return Behavior.Guard(left: left, comparison: comparison, right: nil)
        default:
            guard let right = written.right else {
                throw BehaviorError("\(path) needs `right`: what `\(comparison.rawValue)` compares with.")
            }
            if comparison == .contains { try checkList(left, at: path, doing: "contains") }
            return Behavior.Guard(left: left, comparison: comparison, right: try value(right, at: path))
        }
    }

    // MARK: Actions

    func action(_ written: Behavior.Written.Action, at path: String) throws(BehaviorError) -> Behavior.Action {
        switch written {
        case .set(let field, let value):
            try checkField(field, at: path)
            return .set(field: field, to: try self.value(value, at: path))
        case .add(let value, let field):
            try checkNumber(field, at: path, doing: "added to")
            return .add(try self.value(value, at: path), to: field)
        case .subtract(let value, let field):
            try checkNumber(field, at: path, doing: "subtracted from")
            return .subtract(try self.value(value, at: path), from: field)
        case .append(let value, let field):
            try checkList(.field(field), at: path, doing: "append")
            return .append(try self.value(value, at: path), to: field)
        case .remove(let value, let field):
            try checkList(.field(field), at: path, doing: "remove")
            return .remove(try self.value(value, at: path), from: field)
        case .send(let message, let receiver, let arguments):
            try Signature.checkName(message, what: "message")
            var sent: [Behavior.Argument] = []
            for argument in arguments ?? [] {
                sent.append(Behavior.Argument(name: argument.name, value: try value(argument.value, at: "\(path) in what it sends")))
            }
            return .send(to: try target(receiver, at: path), message: message, arguments: sent)
        case .reply(let value):
            return .reply(try self.value(value, at: path))
        case .reject(let reason):
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BehaviorError("\(path) rejects the message without saying why.")
            }
            return .reject(reason)
        }
    }

    /// Where a message goes: `self`, a parameter or a field holding an object, or another object.
    private func target(_ written: Behavior.Written.Value, at path: String) throws(BehaviorError) -> Behavior.Target {
        switch written {
        case .name("self"): return .me
        case .object(let handle): return .object(handle)
        case .name(let name):
            if let parameter = parameters.first(where: { $0.name == name }) {
                switch parameter.type {
                case .object, .like: return .parameter(name)
                default:
                    throw BehaviorError(
                        "\(path) sends to `\(name)`, but that parameter is \(parameter.type.withArticle), not an object. Give it the type object.")
                }
            }
            if let field = fields[name] {
                switch field {
                case .object, .value(.null): return .field(name)
                case .value(let value):
                    throw BehaviorError(
                        "\(path) sends to `\(name)`, but that field holds `\(value.inline)`, not an object. Start it as the object it talks to.")
                }
            }
            // Not a parameter or a field: another object, by its handle.
            return .object(name)
        default:
            throw BehaviorError("\(path) sends to a value, but a message goes to an object: self, a parameter or field holding one, or an object's handle.")
        }
    }

    // MARK: Values

    /// What a written value means: a parameter, a field, `self`, a literal, or text with values in it.
    func value(_ written: Behavior.Written.Value, at path: String) throws(BehaviorError) -> Behavior.Value {
        switch written {
        case .name("self"): return .me
        case .name(let name):
            if parameters.contains(where: { $0.name == name }) { return .parameter(name) }
            if fields[name] != nil { return .field(name) }
            let known = (parameters.map(\.name) + fields.keys.sorted()).map { "`\($0)`" }.joined(separator: ", ")
            throw BehaviorError(
                "\(path) names `\(name)`, which isn't one of the event's values or its data\(known.isEmpty ? "" : " (those are \(known))"). To mean the words themselves, give them as text.")
        case .number(let number): return .literal(Behavior.literal(number))
        case .text(let text): return try self.text(text, at: path)
        case .boolean(let boolean): return .literal(.bool(boolean))
        case .list(let items): return .literal(.array(items.map(JSONValue.string)))
        case .object(let handle):
            throw BehaviorError("\(path) is the object `\(handle)`, but an object is only where a message is sent, or a field's start.")
        }
    }

    /// Text, with any values written in it: `{count}`, and the other ways models write it,
    /// `{{count}}`, `#{count}`, `${count}` and `\\(count)`. Each is a field or a parameter, filled in
    /// when it runs.
    func text(_ text: String, at path: String) throws(BehaviorError) -> Behavior.Value {
        let pattern = /(?:[#$]?\{\{?\s*\$?([A-Za-z_][A-Za-z0-9_]*)\s*\}?\}|\\\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\))/
        guard text.contains(pattern) else { return .literal(.string(text)) }
        var parts: [Behavior.TextPart] = []
        var rest = Substring(text)
        while let match = rest.firstMatch(of: pattern) {
            if match.range.lowerBound > rest.startIndex { parts.append(.text(String(rest[..<match.range.lowerBound]))) }
            parts.append(.value(try value(.name(String(match.1 ?? match.2 ?? "")), at: path)))
            rest = rest[match.range.upperBound...]
        }
        if !rest.isEmpty { parts.append(.text(String(rest))) }
        return .text(parts)
    }

    private func checkField(_ name: String, at path: String) throws(BehaviorError) {
        guard fields[name] != nil else {
            let known = fields.keys.sorted().map { "`\($0)`" }.joined(separator: ", ")
            throw BehaviorError(
                "\(path) changes `\(name)`, which isn't data it holds\(known.isEmpty ? "" : " (it holds \(known))"). Add it as data first.")
        }
    }

    private func checkNumber(_ name: String, at path: String, doing verb: String) throws(BehaviorError) {
        try checkField(name, at: path)
        if let type = fields[name]?.type, type != .integer, type != .number {
            // A list is added to by appending, and taken from by removing.
            let instead = type == .list ? (verb.hasPrefix("added") ? " To put something in a list, append it." : " To take something out of a list, remove it.") : ""
            throw BehaviorError("\(path): `\(name)` isn't a number, so nothing can be \(verb) it.\(instead)")
        }
    }

    private func checkList(_ value: Behavior.Value, at path: String, doing verb: String) throws(BehaviorError) {
        switch value {
        case .parameter(let name):
            let type = parameters.first { $0.name == name }?.type
            if type == .list || (type == .string && verb == "contains") { return }
            throw BehaviorError("\(path) uses `\(verb)` on `\(name)`, which isn't a list.")
        case .field(let name):
            try checkField(name, at: path)
            let type = fields[name]?.type
            if type == .list || type == nil || (type == .string && verb == "contains") { return }
            throw BehaviorError("\(path) uses `\(verb)` on `\(name)`, which isn't a list. Start it as a list.")
        default:
            throw BehaviorError("\(path) uses `\(verb)` on something that isn't a list field.")
        }
    }
}

extension Behavior.Comparison {
    init(_ written: Behavior.Written.Comparison) {
        switch written {
        case .lessThan: self = .lessThan
        case .atMost: self = .atMost
        case .greaterThan: self = .greaterThan
        case .atLeast: self = .atLeast
        case .equal: self = .equal
        case .notEqual: self = .notEqual
        case .contains: self = .contains
        case .isEmpty: self = .isEmpty
        case .isNotEmpty: self = .isNotEmpty
        }
    }
}

extension ValueType {
    /// A parameter's type: a built-in one, or, for an object, like another object.
    init(_ parameter: Behavior.Written.Parameter, at path: String) throws(BehaviorError) {
        guard let like = parameter.like else {
            self = parameter.type.valueType
            return
        }
        guard parameter.type == .object else {
            throw BehaviorError("\(path) is like `\(like)`, but only an object is like another. Give it the type object.")
        }
        self = .like(like)
    }
}

extension Behavior.Written.Kind {
    var valueType: ValueType {
        switch self {
        case .string: .string
        case .integer: .integer
        case .number: .number
        case .boolean: .boolean
        case .list: .list
        case .object: .object
        }
    }
}

// MARK: - Linking

extension Behavior {
    /// The checks a compiler would make, made when it's defined: every send to an object it knows
    /// is a message that object takes, with arguments that fit.
    func link(objects: [String: MessageProtocol]) throws(BehaviorError) {
        var known = objects
        known[Self.me] = accepted
        let types = Types(protocols: known)

        for clause in clauses {
            let path = "`\(clause.message.name)`"
            for case .send(let target, let message, let arguments) in clause.actions {
                let receiver: MessageProtocol?
                switch target {
                case .me: receiver = accepted
                case .object: receiver = nil  // checked against the object itself, by whoever defines it
                case .parameter(let name):
                    receiver = clause.message.parameters.first { $0.name == name }.flatMap { protocolOf($0.type, known) }
                case .field(let name):
                    receiver = fields[name]?.type.flatMap { protocolOf($0, known) }
                }
                guard let receiver else { continue }
                let shown = target == .me ? "itself" : "`\(receiver.name)`"
                guard let expected = receiver.messages.first(where: { $0.name == message }) else {
                    throw BehaviorError(
                        "\(path) sends `\(message)` to \(shown), which doesn't take it. \(shown.prefix(1).uppercased() + shown.dropFirst()) takes \(receiver.messages.map { "`\($0.written)`" }.joined(separator: ", ")).")
                }
                let given = arguments.map(\.name).sorted()
                guard given == expected.parameters.map(\.name).sorted() else {
                    throw BehaviorError("\(path) sends `\(message)` with \(given.isEmpty ? "nothing" : given.map { "`\($0)`" }.joined(separator: ", ")), but it's `\(expected.written)`.")
                }
                for argument in arguments {
                    let wanted = expected.parameters.first { $0.name == argument.name }!.type
                    guard let type = type(of: argument.value, in: clause) else { continue }
                    guard types.isSubtype(type, of: wanted) else {
                        var why = ""
                        if let want = protocolOf(wanted, known), let actual = protocolOf(type, known),
                            let gap = types.firstGap(in: actual, for: want)
                        { why = ": \(gap)" }
                        throw BehaviorError(
                            "\(path) sends `\(message)` with `\(argument.name)` as \(type == .like(Self.me) ? "itself" : type.withArticle), but `\(expected.written)` takes \(wanted.withArticle) there\(why).")
                    }
                }
            }
        }
    }

    /// How `self` is known while linking.
    static let me = "itself"

    private func protocolOf(_ type: ValueType, _ known: [String: MessageProtocol]) -> MessageProtocol? {
        if case .like(let name) = type { known[name] } else { nil }
    }

    /// What a value is, as far as it's known before it runs.
    private func type(of value: Value, in clause: Clause) -> ValueType? {
        switch value {
        case .literal(let json): ValueType(of: json)
        case .parameter(let name): clause.message.parameters.first { $0.name == name }?.type
        case .field(let name): fields[name]?.type
        case .me: .like(Self.me)
        case .text: .string
        }
    }
}
