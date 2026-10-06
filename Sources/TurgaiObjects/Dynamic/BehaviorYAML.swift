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
        let document: JSONValue
        do {
            document = try YAMLDocument.read(Self.quotingCalls(in: yaml.text))
        } catch {
            throw BehaviorError(error.explanation)
        }
        guard case .object(let members) = document else {
            throw BehaviorError("A behavior is a mapping with `fields` and `receive`, such as:\n\n\(BehaviorError.example)")
        }
        let keys = ["speaks", "fields", "initial", "receive"]
        if let extra = members.keys.sorted().first(where: { !keys.contains($0) }) {
            let hint =
                extra == "behavior" || extra == "name" ? " The name is given on its own, not in the YAML."
                : extra == "protocols" || extra == "protocol" ? " Protocols are given on their own." : ""
            throw BehaviorError(
                "`\(extra)` isn't part of a behavior: it has `receive`, and optionally `speaks`, `fields` and `initial`.\(hint)")
        }

        let speaks: [String]?
        switch members["speaks"] {
        case nil, .null?: speaks = nil
        case .string(let name)?: speaks = [name]
        case .array(let names)?:
            speaks = try names.map { name throws(BehaviorError) in
                guard case .string(let name) = name else {
                    throw BehaviorError("`speaks` names `\(name.inline)`, but it's a list of protocols' names.")
                }
                return name
            }
        case let other?: throw BehaviorError("`speaks` is `\(other.inline)`, but it's a list of protocols' names.")
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

        guard case .array(let written)? = members["receive"], !written.isEmpty else {
            throw BehaviorError(
                "A behavior needs `receive`: a list of clauses, each with `on`, and usually `do`, such as:\n\n\(BehaviorError.example)")
        }
        var clauses: [Clause] = []
        for (index, item) in written.enumerated() {
            clauses.append(try Self.clause(item, at: "receive[\(index)]"))
        }

        let initial: String?
        switch members["initial"] {
        case nil, .null?: initial = nil
        case .string(let state)?: initial = state
        case let other?: throw BehaviorError("`initial` is `\(other.inline)`, but it's the name of a state, such as `idle`.")
        }
        self.init(speaks: speaks, fields: fields, initial: initial, receive: clauses)
    }

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

    private static func clause(_ item: JSONValue, at path: String) throws(BehaviorError) -> Clause {
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
        return Clause(
            on: message, parameters: parameters, when: guards.isEmpty ? nil : guards, actions: actions, in: try state("in"),
            then: try state("then"))
    }

    /// `approve(number: integer)` with its parameters, or `approve` alone, for a message of a
    /// protocol it speaks, whose parameters come from the protocol.
    private static func message(_ text: String, at path: String) throws(BehaviorError) -> (String, [Parameter]?) {
        let signature = try MessageProtocol.Written.signature(text, at: path)
        let parenthesized = text.contains("(")
        return (signature.name, parenthesized ? signature.parameters : nil)
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
        default:
            throw BehaviorError(
                "\(path) is `\(verb)`, but the actions are `set`, `add`, `subtract`, `append`, `remove`, `send` and `reply`.")
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
            if Self.ownKeys.contains(key), value.count >= 2, let quote = value.first, quote == "'" || quote == "\"",
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

// MARK: - Protocols

extension MessageProtocol.Written {
    /// Protocols written together, each name with its messages, one per line:
    ///
    ///     salary answers:
    ///       - raiseApproved(amount: number)
    ///       - raiseDenied(reason: string)
    ///     salary review:
    ///       - raiseRequested(amount: number, worker: salary answers)
    public static func read(yaml: YAML) throws(BehaviorError) -> [MessageProtocol.Written] {
        let document: JSONValue
        do {
            document = try YAMLDocument.read(Behavior.Written.quotingCalls(in: yaml.text))
        } catch {
            throw BehaviorError(error.explanation)
        }
        guard case .object(let written) = document, !written.isEmpty else {
            throw BehaviorError(
                "Protocols are each protocol's name with its messages, one per line, such as:\n\n    salary answers:\n      - raiseApproved(amount: number)\n      - raiseDenied(reason: string)")
        }
        var read: [MessageProtocol.Written] = []
        for name in written.keys.sorted() {
            let lines: [JSONValue]
            switch written[name] {
            case .array(let items)?: lines = items
            case .string?: lines = [written[name]!]
            default:
                throw BehaviorError("`\(name)` is a list of messages, one per line, such as `- raiseApproved(amount: number)`.")
            }
            var messages: [Message] = []
            for item in lines {
                guard case .string(let line) = item else {
                    throw BehaviorError("`\(name)` lists `\(item.inline)`, but each message is one line, such as `raiseApproved(amount: number)`.")
                }
                messages.append(try signature(line, at: "`\(name)`"))
            }
            read.append(MessageProtocol.Written(name: name, messages: messages))
        }
        return read
    }

    /// `name(param: type, …)`, `name()`, or `name`, with an optional `-> type`. A type is a
    /// built-in one, or a protocol's name, for an object that speaks it.
    static func signature(_ text: String, at path: String) throws(BehaviorError) -> Message {
        let syntax: Grammar.SignatureSyntax
        do {
            syntax = try Grammar.read(text, with: SignatureParser())
        } catch {
            throw BehaviorError(
                "\(path): `\(text)` isn't a message. Write it `name(parameter: type, …)`, such as `approve(number: integer)`. The types are string, integer, number, boolean, list, object, or a protocol's name.\n\n\(error.description)")
        }
        let parameters = syntax.parameters.map { parameter in
            if let kind = Behavior.Written.Kind(rawValue: parameter.type) {
                return Behavior.Written.Parameter(name: parameter.name, type: kind, speaks: nil)
            }
            return Behavior.Written.Parameter(name: parameter.name, type: .object, speaks: parameter.type)
        }
        return Message(name: syntax.name, parameters: parameters, reply: syntax.reply.flatMap(Behavior.Written.Kind.init(rawValue:)))
    }
}

// MARK: - Shown as YAML

extension Behavior.Written {
    /// The spec as YAML, to show it back the way specs are read.
    public var yaml: YAML {
        var lines: [String] = []
        if let speaks, !speaks.isEmpty { lines.append("speaks: [\(speaks.joined(separator: ", "))]") }
        if !fields.isEmpty {
            lines.append("fields:")
            lines += fields.map { "  \($0.name): \(Self.shown($0.start))" }
        }
        if let initial { lines.append("initial: \(initial)") }
        lines.append("receive:")
        for clause in receive {
            let parameters = clause.parameters.map { "(" + $0.map { "\($0.name): \($0.speaks ?? $0.type.rawValue)" }.joined(separator: ", ") + ")" } ?? ""
            lines.append("  - on: \(clause.on)\(parameters)")
            if let state = clause.in { lines.append("    in: \(state)") }
            for check in clause.when ?? [] {
                let right = check.right.map { " \(Self.shown($0))" } ?? ""
                lines.append("    when: \(Self.shown(check.left)) \(Behavior.Comparison(check.comparison).rawValue)\(right)")
            }
            if !clause.actions.isEmpty { lines.append("    do:") }
            for action in clause.actions {
                switch action {
                case .set(let field, let value): lines.append("      - set: \(field) to \(Self.shown(value))")
                case .add(let value, let field): lines.append("      - add: \(Self.shown(value)) to \(field)")
                case .subtract(let value, let field): lines.append("      - subtract: \(Self.shown(value)) from \(field)")
                case .append(let value, let field): lines.append("      - append: \(Self.shown(value)) to \(field)")
                case .remove(let value, let field): lines.append("      - remove: \(Self.shown(value)) from \(field)")
                case .send(let message, let to, let arguments):
                    let given = (arguments ?? []).map { "\($0.name): \(Self.shown($0.value))" }.joined(separator: ", ")
                    lines.append("      - send: \(Self.shown(to)).\(message)(\(given))")
                case .reply(let value): lines.append("      - reply: \(Self.shown(value))")
                }
            }
            if let next = clause.then { lines.append("    then: \(next)") }
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
}

extension Behavior {
    /// Reads a behavior written as YAML.
    public init(name: String, yaml: YAML, protocols: [String: MessageProtocol] = [:]) throws(BehaviorError) {
        try self.init(name: name, written: try Written(yaml: yaml), protocols: protocols)
    }
}

extension Spec {
    /// A new behavior from a spec written as YAML, with any protocols it introduces, as YAML too.
    public static func yaml(_ spec: YAML, protocols: YAML? = nil) throws(BehaviorError) -> Spec {
        .written(try Behavior.Written(yaml: spec), protocols: try protocols.map { (yaml: YAML) throws(BehaviorError) in try MessageProtocol.Written.read(yaml: yaml) } ?? [])
    }
}

extension Change {
    /// A new spec, written as YAML.
    public static func spec(yaml: YAML) throws(BehaviorError) -> Change {
        .spec(try Behavior.Written(yaml: yaml))
    }

    /// Protocols, new or changed, written as YAML.
    public static func protocols(yaml: YAML) throws(BehaviorError) -> Change {
        .protocols(try MessageProtocol.Written.read(yaml: yaml))
    }
}
