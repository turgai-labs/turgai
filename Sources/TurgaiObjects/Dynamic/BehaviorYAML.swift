import DiscoverableActors
import Foundation
import Parsing

// Specs and protocols written as YAML, read into the typed form a behavior is read from, and
// the typed form shown back as YAML. Nothing else depends on YAML.

extension Behavior.Written {
    /// Reads a spec written as YAML:
    ///
    ///     fields:
    ///       count: 0
    ///     receive:
    ///       - on: addCup()
    ///         do:
    ///           - add: 1 to count
    ///       - on: howMany()
    ///         reply: count
    public init(yaml: YAML) throws(BehaviorError) {
        try self.init(document: try Self.document(yaml))
    }

    /// A spec, or a piece of one, as the document a spec is read from: what a draft written a
    /// piece at a time puts together before reading it whole.
    public static func document(_ yaml: YAML) throws(BehaviorError) -> JSONValue {
        do {
            return try YAMLDocument.read(Self.quotingCalls(in: yaml.text))
        } catch {
            throw BehaviorError(error.explanation)
        }
    }

    /// Reads a spec from its document, as ``init(yaml:)`` does once the YAML is read.
    public init(document: JSONValue) throws(BehaviorError) {
        guard case .object(let members) = document else {
            throw BehaviorError("A behavior is a mapping with `fields` and `receive`, such as:\n\n\(BehaviorError.example)")
        }
        let keys = ["fields", "initial", "receive"]
        if let extra = members.keys.sorted().first(where: { !keys.contains($0) }) {
            let hint =
                extra == "behavior" || extra == "name" ? " The name is given on its own, not in the YAML."
                : extra == "speaks" ? " An object's type is its behavior: a parameter like another object is written `worker: bob`." : ""
            throw BehaviorError(
                "`\(extra)` isn't part of a behavior: it has `receive`, and optionally `fields` and `initial`.\(hint)")
        }

        var fields: [Field] = []
        switch members["fields"] {
        case nil, .null?: break
        case .object(let declared)?:
            for (name, value) in declared.sorted(by: { $0.key < $1.key }) {
                fields.append(Field(name: name, start: try Self.start(value, of: name)))
            }
        case let other?:
            throw BehaviorError(
                "`fields` is `\(other.inline)`, but it's each field with its starting value, such as:\n\n    fields:\n      count: 0\n      names: []")
        }

        // No `receive` is no behavior yet: an object that handles nothing, as an actor can start.
        let written: [JSONValue]
        switch members["receive"] {
        case nil: written = []
        case .array(let items)?: written = items
        case let other?:
            throw BehaviorError(
                "`receive` is `\(other.inline)`, but it's a list of clauses, each with `on`, and usually `do`, such as:\n\n\(BehaviorError.example)")
        }
        var clauses: [(clause: Clause, in: String?, then: String?)] = []
        for (index, item) in written.enumerated() {
            clauses.append(try Self.clause(item, at: "receive[\(index)]"))
        }

        let initial: String?
        switch members["initial"] {
        case nil, .null?: initial = nil
        case .string(let state)?: initial = state
        case let other?: throw BehaviorError("`initial` is `\(other.inline)`, but it's the name of a state, such as `idle`.")
        }
        // States are a field: `in: idle` is a guard on it, and `then: busy` sets it.
        guard let start = initial ?? clauses.lazy.compactMap(\.in).first ?? clauses.lazy.compactMap(\.then).first else {
            self.init(fields: fields, receive: clauses.map(\.clause))
            return
        }
        guard !fields.contains(where: { $0.name == Self.stateField }) else {
            throw BehaviorError("`\(Self.stateField)` is a field, and a behavior with states keeps its state there. Name the field differently.")
        }
        let receive = clauses.map { written in
            let clause = written.clause
            let guarded = written.in.map { [Guard(left: .name(Self.stateField), comparison: .equal, right: .text($0))] } ?? []
            let moved = written.then.map { [Action.set(field: Self.stateField, to: .text($0))] } ?? []
            let when = guarded + (clause.when ?? [])
            return Clause(on: clause.on, parameters: clause.parameters, when: when.isEmpty ? nil : when, actions: clause.actions + moved)
        }
        self.init(fields: fields + [Field(name: Self.stateField, start: .text(start))], receive: receive)
    }

    /// The field a behavior with states keeps its state in.
    static let stateField = "state"

    /// `count: 0`, or `manager: {object: Ann}` for another object.
    private static func start(_ value: JSONValue, of field: String) throws(BehaviorError) -> Value {
        switch value {
        case .object(let members) where members.count == 1:
            if case .string(let handle)? = members["object"] { return .object(handle) }
        case .integer(let integer): return .number(Double(integer))
        case .unsignedInteger(let integer): return .number(Double(integer))
        case .number(let number): return .number(number)
        case .string(let text): return .text(text)
        case .bool(let boolean): return .boolean(boolean)
        case .array(let items):
            let texts = items.compactMap { item -> String? in
                if case .string(let text) = item { return text }
                return nil
            }
            if texts.count == items.count { return .list(texts) }
        default: break
        }
        throw BehaviorError(
            "`\(field)` starts as `\(value.inline)`, but a field starts as a number, text, true or false, a list of text, or `{object: Name}`.")
    }

    private static func clause(_ item: JSONValue, at path: String) throws(BehaviorError) -> (clause: Clause, in: String?, then: String?) {
        guard case .object(let members) = item else {
            throw BehaviorError("\(path) is `\(item.inline)`, but a clause is a mapping with `on` and `do`, such as:\n\n\(BehaviorError.example)")
        }
        if let extra = members.keys.sorted().first(where: { !["in", "on", "when", "do", "reply", "then"].contains($0) }) {
            throw BehaviorError("\(path) has `\(extra)`, but a clause has `on`, `when`, `do`, and optionally `in`, `reply` and `then`.")
        }
        guard case .string(let on)? = members["on"] else {
            throw BehaviorError("\(path) needs `on`: the message it handles, such as `on: approve(number: integer)`.")
        }
        let (message, parameters) = try Self.message(on, at: "\(path).on")
        let path = "\(path) (`\(message)`)"

        var guards: [Guard] = []
        switch members["when"] {
        case nil, .null?, .bool(true)?: break
        case .string(let text)? where Self.always(text): break
        case .string(let text)?: guards.append(try Self.guarded(text, at: "\(path).when"))
        case .array(let items)?:
            for (index, item) in items.enumerated() {
                guard case .string(let text) = item else {
                    throw BehaviorError("\(path).when[\(index)] is `\(item.inline)`, but a guard is text, such as `total < 50`.")
                }
                guards.append(try Self.guarded(text, at: "\(path).when[\(index)]"))
            }
        case let other?:
            throw BehaviorError("\(path).when is `\(other.inline)`, but a guard is text, such as `total < 50`, or a list of them.")
        }

        var actions: [Action] = []
        switch members["do"] {
        case nil, .null?: break
        case .array(let items)?:
            for (index, item) in items.enumerated() { actions.append(try Self.action(item, at: "\(path).do[\(index)]")) }
        case .object(let written)?:
            // Actions written as a mapping: shown back as the list they should be, with `reply`
            // moved out next to `do`, where it belongs.
            let actions = written.filter { $0.key != "reply" }.sorted { $0.key < $1.key }
            let reply = written["reply"].map { "\n    reply: \($0.inline)" } ?? ""
            throw BehaviorError(
                "\(path).do is a mapping, but it's a list: each action on a line of its own, starting with `- `, in the order they run, such as:\n\n    do:\n"
                    + actions.map { "      - \($0.key): \($0.value.inline)" }.joined(separator: "\n") + reply)
        case let other?:
            throw BehaviorError("\(path).do is `\(other.inline)`, but it's a list of actions, such as:\n\n    do:\n      - add: 1 to count")
        }
        if let reply = members["reply"] {
            actions.append(try Self.action(["reply": reply], at: "\(path).reply"))
        }

        func state(_ key: String) throws(BehaviorError) -> String? {
            switch members[key] {
            case nil, .null?: return nil
            case .string(let name)?: return name
            case let other?: throw BehaviorError("\(path).\(key) is `\(other.inline)`, but it's the name of a state, such as `idle`.")
            }
        }
        return (
            Clause(on: message, parameters: parameters, when: guards.isEmpty ? nil : guards, actions: actions),
            try state("in"), try state("then")
        )
    }

    /// A name made from what was written in its place, such as `addCup` for `add cup`: one word,
    /// as messages, fields and parameters are named.
    public static func messageName(from text: String) -> String {
        let words = (text.split(separator: "(").first.map(String.init) ?? text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard let first = words.first else { return "approve" }
        // Words are joined, each after the first starting with a capital; a word's own capitals
        // stay, so `approveBelow` is left as it is.
        return first.prefix(1).lowercased() + first.dropFirst() + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// `approve(number: integer)`, or `approve` for one without parameters. A type is a built-in
    /// one, or the handle of an object, for an object like it: `worker: bob`.
    private static func message(_ text: String, at path: String) throws(BehaviorError) -> (String, [Parameter]?) {
        let syntax: Grammar.SignatureSyntax
        do {
            syntax = try Grammar.read(text, with: SignatureParser())
        } catch {
            // The example is made from its own words, so it isn't copied as a template.
            let name = Self.messageName(from: text)
            throw BehaviorError(
                "\(path): `\(text)` isn't a message. A message is one word, with its parameters in parentheses: `\(name)()`, or `\(name)(amount: number)` with one. A parameter's type is string, integer, number, boolean, list, object, or an object's handle, for an object like it.\n\n\(error.description)")
        }
        let parameters = syntax.parameters.map { parameter in
            if let kind = Kind(rawValue: parameter.type) {
                return Parameter(name: parameter.name, type: kind, like: nil)
            }
            return Parameter(name: parameter.name, type: .object, like: parameter.type)
        }
        return (syntax.name, parameters.isEmpty ? nil : parameters)
    }

    // MARK: Guards

    /// A condition that always holds, written where none is needed: `true`, or nothing.
    static func always(_ text: String) -> Bool {
        ["", "true", "always"].contains(text.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private static func guarded(_ text: String, at path: String) throws(BehaviorError) -> Guard {
        let syntax: Grammar.GuardSyntax
        do {
            syntax = try Grammar.read(text, with: GuardParser())
        } catch {
            throw BehaviorError(
                "\(path) is `\(text)`, but a guard compares two values with <, <=, >, >=, == or !=, or checks a list: `names contains name`, `names is empty`, `names is not empty`.\n\n\(error.description)")
        }
        switch syntax {
        case .check(let left, let comparison):
            return Guard(left: try value(left, at: path), comparison: Comparison(comparison), right: nil)
        case .compare(let left, let comparison, let right):
            return Guard(left: try value(left, at: path), comparison: Comparison(comparison), right: try value(right, at: path))
        }
    }

    // MARK: Actions

    private static func action(_ item: JSONValue, at path: String) throws(BehaviorError) -> Action {
        guard case .object(let members) = item, members.count == 1, let (verb, argument) = members.first else {
            throw BehaviorError(
                "\(path) is `\(item.inline)`, but an action is one of `set: field to value`, `add: number to field`, `subtract: number from field`, `append: value to field`, `remove: value from field`, `send: object.message(arguments)` or `reply: value`.")
        }
        let text: String
        switch argument {
        case .string(let string): text = string
        case .integer, .unsignedInteger, .number, .bool, .null: text = argument.inline
        default:
            throw BehaviorError("\(path) is `\(verb): \(argument.inline)`, but its value is one line of text, such as `\(verb): \(Self.shape(of: verb))`.")
        }
        func read<P: Parser<Substring, Output>, Output>(_ parser: P) throws(BehaviorError) -> Output {
            do {
                return try Grammar.read(text, with: parser)
            } catch {
                let single =
                    text.contains("{") || text.contains("[")
                    ? " Values are single: a parameter, a field, a number, or quoted text. Store one value, such as the number."
                    : ""
                throw BehaviorError("\(path) is `\(verb): \(text)`, but it's written `\(verb): \(Self.shape(of: verb))`.\(single)\n\n\(error.description)")
            }
        }
        switch verb {
        case "set":
            let (field, value) = try read(FieldToValue())
            return .set(field: field, to: try self.value(value, at: path))
        case "add":
            let (value, field) = try read(ValueThenField(word: "to"))
            return .add(try self.value(value, at: path), to: field)
        case "subtract":
            let (value, field) = try read(ValueThenField(word: "from"))
            return .subtract(try self.value(value, at: path), from: field)
        case "append":
            let (value, field) = try read(ValueThenField(word: "to"))
            return .append(try self.value(value, at: path), to: field)
        case "remove":
            let (value, field) = try read(ValueThenField(word: "from"))
            return .remove(try self.value(value, at: path), from: field)
        case "send":
            if let dot = text.firstIndex(of: "."), text[text.index(after: dot)...].prefix(while: { $0 != "(" }).contains(".") {
                throw BehaviorError(
                    "\(path) is `send: \(text)`, but a send goes to one object: a parameter, a field, `self`, or an object's handle. To send through a field, write it without `\(text[..<dot]).`.")
            }
            let syntax = try read(SendParser())
            var arguments: [Argument] = []
            for argument in syntax.arguments {
                arguments.append(Argument(name: argument.name, value: try value(argument.value, at: path)))
            }
            return .send(message: syntax.message, to: .name(syntax.receiver), arguments: arguments.isEmpty ? nil : arguments)
        case "reply":
            return .reply(try value(try read(ValueParser()), at: path))
        case "reject":
            return .reject(text)
        default:
            throw BehaviorError(
                "\(path) is `\(verb)`, but the actions are `set`, `add`, `subtract`, `append`, `remove`, `send`, `reply` and `reject`.")
        }
    }

    private static func shape(of verb: String) -> String {
        switch verb {
        case "set": "count to 0"
        case "add": "1 to count"
        case "subtract": "amount from remaining"
        case "append": "item to items"
        case "remove": "item from items"
        case "send": "shop.refundApproved(number)"
        default: "count"
        }
    }

    // MARK: Values

    /// A value as written: quoted text, a number, an empty list, `true` or `false`, or a name.
    private static func value(_ syntax: Grammar.Value, at path: String) throws(BehaviorError) -> Value {
        switch syntax {
        case .text(let text): .text(text)
        case .integer(let integer): .number(Double(integer))
        case .number(let number): .number(number)
        case .emptyList: .list([])
        case .word("true"): .boolean(true)
        case .word("false"): .boolean(false)
        case .word(let name): .name(name)
        }
    }

    /// Quotes a value written as a call, such as `on: approve(number: integer)` or
    /// `send: shop.refundApproved(number: n)`, which YAML would otherwise read as a second key at
    /// the `: ` inside the parentheses. The call syntax is ours, so the reader quotes it, rather than
    /// asking for quotes the way it must for other YAML.
    /// The keys whose values are ours to read, not YAML's: actions, guards and replies.
    static let ownKeys: Set<String> = ["set", "add", "subtract", "append", "remove", "send", "reply", "when"]

    static func quotingCalls(in yaml: String) -> String {
        yaml.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            // A list item that's a call, such as `- raiseApproved(amount: number)`.
            let item = line.drop { $0 == " " }
            if item.hasPrefix("- "), let open = item.firstIndex(of: "("),
                !item[item.index(item.startIndex, offsetBy: 2)..<open].contains(":"), item.hasSuffix(")"), item[open...].contains(":")
            {
                let indent = line.prefix { $0 == " " }
                let call = item.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return indent + "- '" + call.replacingOccurrences(of: "'", with: "''") + "'"
            }
            guard let colon = line.range(of: ": ") else { return String(line) }
            let value = line[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            // Quoted text in an action or a guard is text: YAML would drop its quotes, and the
            // value would then read as a name.
            let key = line[..<colon.lowerBound].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "- ", with: "")
            if ["reply", "when"].contains(key), value.count >= 2, let quote = value.first, quote == "'" || quote == "\"",
                value.last == quote
            {
                let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let wrapped = quote == "'" ? "\"" + escaped + "\"" : "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
                return line[..<colon.upperBound] + wrapped
            }
            guard let first = value.first, first != "'", first != "\"", first != "{", first != "[",
                let open = value.firstIndex(of: "("), value.hasSuffix(")"),
                value[open...].contains(":")
            else { return String(line) }
            return line[..<colon.upperBound] + "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }.joined(separator: "\n")
    }
}

extension Behavior.Written.Comparison {
    init(_ comparison: Behavior.Comparison) {
        switch comparison {
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

// MARK: - Shown as YAML

extension Behavior.Written {
    /// The spec as YAML, to show it back the way specs are read.
    public var yaml: YAML {
        var lines: [String] = []
        if !fields.isEmpty {
            lines.append("fields:")
            lines += fields.map { "  \($0.name): \(Self.shown($0.start))" }
        }
        lines.append(receive.isEmpty ? "receive: []" : "receive:")
        for clause in receive {
            let parameters = clause.parameters.map { "(" + $0.map { "\($0.name): \($0.like ?? $0.type.rawValue)" }.joined(separator: ", ") + ")" } ?? ""
            lines.append("  - on: \(clause.on)\(parameters)")
            for check in clause.when ?? [] {
                let right = check.right.map { " \(Self.shown($0))" } ?? ""
                lines.append("    when: \(Self.shown(check.left)) \(Behavior.Comparison(check.comparison).rawValue)\(right)")
            }
            if !clause.actions.isEmpty { lines.append("    do:") }
            for action in clause.actions {
                switch action {
                case .set(let field, let value): lines.append("      - set: \(Self.scalar("\(field) to \(Self.shown(value))"))")
                case .add(let value, let field): lines.append("      - add: \(Self.scalar("\(Self.shown(value)) to \(field)"))")
                case .subtract(let value, let field): lines.append("      - subtract: \(Self.scalar("\(Self.shown(value)) from \(field)"))")
                case .append(let value, let field): lines.append("      - append: \(Self.scalar("\(Self.shown(value)) to \(field)"))")
                case .remove(let value, let field): lines.append("      - remove: \(Self.scalar("\(Self.shown(value)) from \(field)"))")
                case .send(let message, let to, let arguments):
                    let given = (arguments ?? []).map { "\($0.name): \(Self.shown($0.value))" }.joined(separator: ", ")
                    lines.append("      - send: \(Self.scalar("\(Self.shown(to)).\(message)(\(given))"))")
                case .reply(let value): lines.append("      - reply: \(Self.shown(value))")
                case .reject(let reason): lines.append("      - reject: \(Self.scalar(reason))")
                }
            }
        }
        return YAML(lines.joined(separator: "\n"))
    }

    private static func shown(_ value: Value) -> String {
        switch value {
        case .name(let name): name
        case .number(let number): Behavior.literal(number).inline
        case .text(let text): "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
        case .boolean(let boolean): String(boolean)
        case .list(let items): "[" + items.map { "'\($0)'" }.joined(separator: ", ") + "]"
        case .object(let handle): "{object: \(handle)}"
        }
    }

    /// An action is parsed as one expression. Quote the whole YAML scalar so quoted text inside
    /// it, such as `'milk' from items`, survives a show/read round trip.
    private static func scalar(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

extension Behavior {
    /// Reads a behavior written as YAML.
    public init(name: String, yaml: YAML, objects: [String: MessageProtocol] = [:]) throws(BehaviorError) {
        try self.init(name: name, written: try Written(yaml: yaml), objects: objects)
    }
}

extension Spec {
    /// A new behavior from a spec written as YAML.
    public static func yaml(_ spec: YAML) throws(BehaviorError) -> Spec {
        .written(try Behavior.Written(yaml: spec))
    }
}
