import DiscoverableActors
import Foundation

extension Behavior {
    /// Reads a behavior named `name` from its spec and links it: everything that can be checked
    /// without other objects running. Names, types and states; that it handles every protocol it
    /// speaks; and that each send through a typed reference is a message that reference accepts.
    /// Errors name the part of the spec, such as `receive[0].actions[1]`.
    /// - Parameter protocols: The protocols it can speak and type parameters with, by name.
    public init(name: String, written: Written, protocols: [String: MessageProtocol] = [:]) throws(BehaviorError) {
        var speaks: [MessageProtocol] = []
        for (index, spoken) in (written.speaks ?? []).enumerated() {
            guard let found = protocols[spoken] else {
                throw BehaviorError("speaks[\(index)] is `\(spoken)`, which isn't a protocol\(Self.known(protocols)).")
            }
            speaks.append(found)
        }

        var fields: [String: Field] = [:]
        for (index, field) in written.fields.enumerated() {
            try Signature.checkName(field.name, what: "field")
            guard fields[field.name] == nil else { throw BehaviorError("fields[\(index)]: `\(field.name)` is there twice.") }
            fields[field.name] = try Field(start: field.start, at: "fields[\(index)].start (`\(field.name)`)")
        }

        guard !written.receive.isEmpty else {
            throw BehaviorError("`receive` is empty: give a clause for each message it takes.")
        }
        var clauses: [Clause] = []
        for (index, clause) in written.receive.enumerated() {
            var reader = Reader(fields: fields, speaks: speaks, protocols: protocols)
            clauses.append(try reader.clause(clause, at: "receive[\(index)]"))
        }
        for clause in clauses {
            if let first = clauses.first(where: { $0.message.name == clause.message.name }),
                first.message.parameters != clause.message.parameters
            {
                throw BehaviorError(
                    "`\(clause.message.name)` has different parameters in different clauses. Give them the same in each: `\(first.message.written)`.")
            }
        }

        let initial = written.initial ?? clauses.lazy.compactMap(\.state).first
        let states = Set(clauses.compactMap(\.state) + [initial].compactMap { $0 })
        for (index, clause) in clauses.enumerated() {
            if let next = clause.next, !states.contains(next) {
                throw BehaviorError(
                    "receive[\(index)] (`\(clause.message.name)`) goes to `\(next)`, but no clause is in `\(next)`, so an object there would take no messages. The states are: \(states.sorted().joined(separator: ", ")).")
            }
        }
        self.init(name: name, source: written, speaks: speaks, fields: fields, initial: initial, clauses: clauses)
        try link(protocols: protocols)
    }

    /// ` (those are `a`, `b`)`, the protocols there are, or nothing.
    static func known(_ protocols: [String: MessageProtocol]) -> String {
        let names = protocols.keys.sorted().map { "`\($0)`" }.joined(separator: ", ")
        return names.isEmpty ? "" : " (those are \(names))"
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

    /// Start values given as fields, such as `limit` starting at 20, for an object that starts
    /// with values of its own.
    public static func values(_ fields: [Behavior.Written.Field]) throws(BehaviorError) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for (index, field) in fields.enumerated() {
            values[field.name] = try Behavior.Field(start: field.start, at: "start[\(index)] (`\(field.name)`)").initial
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
    let speaks: [MessageProtocol]
    let protocols: [String: MessageProtocol]
    var parameters: [Parameter] = []

    init(fields: [String: Behavior.Field], speaks: [MessageProtocol], protocols: [String: MessageProtocol]) {
        self.fields = fields
        self.speaks = speaks
        self.protocols = protocols
    }

    mutating func clause(_ written: Behavior.Written.Clause, at path: String) throws(BehaviorError) -> Behavior.Clause {
        let message = try self.message(written, at: path)
        parameters = message.parameters
        let path = "\(path) (`\(message.name)`)"
        var guards: [Behavior.Guard] = []
        for (index, written) in (written.when ?? []).enumerated() {
            guards.append(try guarded(written, at: "\(path).when[\(index)]"))
        }
        var actions: [Behavior.Action] = []
        for (index, action) in written.actions.enumerated() {
            actions.append(try self.action(action, at: "\(path).actions[\(index)]"))
        }
        return Behavior.Clause(state: written.in, message: message, guards: guards, actions: actions, next: written.then)
    }

    /// The message a clause handles: one of a protocol it speaks, by name, or one of its own, with
    /// its parameters.
    private func message(_ written: Behavior.Written.Clause, at path: String) throws(BehaviorError) -> Signature {
        try Signature.checkName(written.on, what: "message")
        var parameters: [Parameter] = []
        for (index, parameter) in (written.parameters ?? []).enumerated() {
            try Signature.checkName(parameter.name, what: "parameter")
            guard !parameters.contains(where: { $0.name == parameter.name }) else {
                throw BehaviorError("\(path).parameters[\(index)]: `\(parameter.name)` is there twice.")
            }
            parameters.append(
                Parameter(name: parameter.name, type: try ValueType(parameter, at: "\(path).parameters[\(index)]", protocols: protocols)))
        }
        guard let spoken = speaks.lazy.flatMap(\.messages).first(where: { $0.name == written.on }) else {
            return Signature(name: written.on, parameters: parameters)
        }
        if written.parameters != nil, spoken.parameters != parameters {
            throw BehaviorError(
                "\(path).on is `\(written.on)`, which it speaks as `\(spoken.written)`. Leave out its parameters: they come from the protocol.")
        }
        return spoken
    }

    // MARK: Guards

    func guarded(_ written: Behavior.Written.Guard, at path: String) throws(BehaviorError) -> Behavior.Guard {
        let left = try value(written.left, at: "\(path).left")
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
            return Behavior.Guard(left: left, comparison: comparison, right: try value(right, at: "\(path).right"))
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
            for (index, argument) in (arguments ?? []).enumerated() {
                sent.append(Behavior.Argument(name: argument.name, value: try value(argument.value, at: "\(path).arguments[\(index)]")))
            }
            return .send(to: try target(receiver, at: path), message: message, arguments: sent)
        case .reply(let value):
            return .reply(try self.value(value, at: path))
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
                case .object, .speaks: return .parameter(name)
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
                "\(path) names `\(name)`, which isn't a parameter or a field\(known.isEmpty ? "" : " (those are \(known))"). To mean the words themselves, give them as text.")
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
                "\(path) changes `\(name)`, which isn't a field\(known.isEmpty ? "" : " (those are \(known))"). Add it to `fields` with its starting value.")
        }
    }

    private func checkNumber(_ name: String, at path: String, doing verb: String) throws(BehaviorError) {
        try checkField(name, at: path)
        if let type = fields[name]?.type, type != .integer, type != .number {
            throw BehaviorError("\(path): `\(name)` isn't a number, so nothing can be \(verb) it.")
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
    /// A parameter's type: a built-in one, or, for an object, the protocol it speaks.
    init(_ parameter: Behavior.Written.Parameter, at path: String, protocols: [String: MessageProtocol]) throws(BehaviorError) {
        guard let spoken = parameter.speaks else {
            self = parameter.type.valueType
            return
        }
        guard parameter.type == .object else {
            throw BehaviorError("\(path) speaks `\(spoken)`, but only an object speaks a protocol. Give it the type object.")
        }
        guard protocols[spoken] != nil else {
            throw BehaviorError("\(path) speaks `\(spoken)`, which isn't a protocol\(Behavior.known(protocols)).")
        }
        self = .speaks(spoken)
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
    /// The checks a compiler would make, made when it's defined: it handles every protocol it
    /// speaks, replies where a protocol asks for a reply, and every send through a typed reference
    /// is a message that reference accepts, with arguments that fit.
    func link(protocols: [String: MessageProtocol]) throws(BehaviorError) {
        var known = protocols
        known[Self.me] = accepted
        let types = Types(protocols: known)

        for spoken in speaks {
            if let gap = types.firstGap(in: accepted, for: spoken) {
                let missing = spoken.messages.first { wanted in !messages.contains { $0.name == wanted.name } }
                throw BehaviorError(
                    "It speaks `\(spoken.name)`, but \(gap).\(missing.map { " Add a clause on `\($0.name)`." } ?? "")")
            }
            for wanted in spoken.messages where wanted.reply != nil {
                for clause in clauses where clause.message.name == wanted.name {
                    guard clause.actions.contains(where: { if case .reply = $0 { true } else { false } }) else {
                        throw BehaviorError("`\(wanted.written)` expects a reply, but a clause for `\(wanted.name)` doesn't reply.")
                    }
                }
            }
        }

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
                            "\(path) sends `\(message)` with `\(argument.name)` as \(type == .speaks(Self.me) ? "itself" : type.withArticle), but `\(expected.written)` takes \(wanted.withArticle) there\(why).")
                    }
                }
            }
        }
    }

    /// How `self` is known while linking.
    static let me = "itself"

    /// A newer spec keeps speaking what this one does, so objects that count on it keep working.
    public func check(replacing older: Behavior) throws(BehaviorError) {
        for spoken in older.speaks where !speaks.contains(where: { $0.name == spoken.name }) {
            throw BehaviorError(
                "The spec before spoke `\(spoken.name)`, and other objects may count on that. Keep `\(spoken.name)` in `speaks`.")
        }
    }

    private func protocolOf(_ type: ValueType, _ known: [String: MessageProtocol]) -> MessageProtocol? {
        if case .speaks(let name) = type { known[name] } else { nil }
    }

    /// What a value is, as far as it's known before it runs.
    private func type(of value: Value, in clause: Clause) -> ValueType? {
        switch value {
        case .literal(let json): ValueType(of: json)
        case .parameter(let name): clause.message.parameters.first { $0.name == name }?.type
        case .field(let name): fields[name]?.type
        case .me: .speaks(Self.me)
        case .text: .string
        }
    }
}
