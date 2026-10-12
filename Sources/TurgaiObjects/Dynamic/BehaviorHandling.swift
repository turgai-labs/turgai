import DiscoverableActors
import Foundation

// MARK: - Handling a message

extension Behavior {
    /// What handling one message does: the fields after it, what to send, and the reply. Nothing
    /// happens until whoever runs it applies this.
    public struct Outcome: Sendable, Equatable {
        public var fields: [String: JSONValue]
        public var sends: [Send]
        public var reply: JSONValue
    }

    public struct Send: Sendable, Equatable {
        /// An object's reference, or another object's name.
        public enum Recipient: Sendable, Equatable {
            case reference(JSONValue)
            case named(String)
            case me
        }

        public let recipient: Recipient
        public let message: String
        public let arguments: JSONValue
    }

    /// Handles `message` the way `receive` does: the first clause for it whose guards hold. It's
    /// pure: the fields given aren't changed, and nothing is sent.
    public func handle(_ message: String, arguments: JSONValue, fields: [String: JSONValue]) throws(BehaviorError) -> Outcome {
        let candidates = clauses.filter { $0.message.name == message }
        guard let first = candidates.first else {
            let takes = messages.map { "`\($0.name)`" }.joined(separator: ", ")
            throw BehaviorError("It has no message `\(message)`. It takes \(takes.isEmpty ? "nothing" : takes).")
        }
        let given = try Self.bind(arguments, to: first.message)
        var unmet: [String] = []
        for clause in candidates {
            let scope = Scope(parameters: given, fields: fields)
            var failed: Guard?
            for condition in clause.guards where !(try scope.holds(condition)) {
                failed = condition
                break
            }
            if let failed {
                unmet.append(scope.describe(failed))
                continue
            }
            return try run(clause, scope: scope)
        }
        throw BehaviorError("`\(message)` was refused: \(unmet.joined(separator: "; and ")).")
    }

    private func run(_ clause: Clause, scope: Scope) throws(BehaviorError) -> Outcome {
        var scope = scope
        var outcome = Outcome(fields: scope.fields, sends: [], reply: .null)
        for action in clause.actions {
            switch action {
            case .set(let field, let value):
                scope.fields[field] = try scope.resolve(value)
            case .add(let value, let field):
                let amount = try scope.resolve(value)
                let current = scope.fields[field] ?? .integer(0)
                guard let sum = current.adding(amount) else {
                    throw BehaviorError("It can't add `\(amount.inline)` to `\(field)`, which is `\(current.inline)`: both have to be numbers.")
                }
                scope.fields[field] = sum
            case .subtract(let value, let field):
                let amount = try scope.resolve(value)
                let current = scope.fields[field] ?? .integer(0)
                guard let difference = amount.negated.flatMap(current.adding) else {
                    throw BehaviorError("It can't subtract `\(amount.inline)` from `\(field)`, which is `\(current.inline)`: both have to be numbers.")
                }
                scope.fields[field] = difference
            case .append(let value, let field):
                guard case .array(var items) = scope.fields[field] ?? [] else {
                    throw BehaviorError("It can't append to `\(field)`, which isn't a list.")
                }
                items.append(try scope.resolve(value))
                scope.fields[field] = .array(items)
            case .remove(let value, let field):
                guard case .array(var items) = scope.fields[field] ?? [] else {
                    throw BehaviorError("It can't remove from `\(field)`, which isn't a list.")
                }
                let removed = try scope.resolve(value)
                items.removeAll { $0.sameValue(as: removed) }
                scope.fields[field] = .array(items)
            case .send(let target, let message, let arguments):
                var values: [String: JSONValue] = [:]
                for argument in arguments { values[argument.name] = try scope.resolve(argument.value) }
                let recipient: Send.Recipient =
                    switch target {
                    case .me: .me
                    case .object(let name): .named(name)
                    case .parameter(let name): .reference(scope.parameters[name] ?? .null)
                    case .field(let name): .reference(scope.fields[name] ?? .null)
                    }
                outcome.sends.append(Send(recipient: recipient, message: message, arguments: .object(values)))
            case .reply(let value):
                outcome.reply = try scope.resolve(value)
            case .reject(let reason):
                throw BehaviorError(reason)
            }
        }
        outcome.fields = scope.fields
        return outcome
    }

    /// The arguments by parameter, each of its type, none missing and none extra.
    private static func bind(_ arguments: JSONValue, to signature: Signature) throws(BehaviorError) -> [String: JSONValue] {
        let message = signature.name
        let parameters = signature.parameters
        let given: [String: JSONValue]
        switch arguments {
        case .object(let members): given = members
        case .null: given = [:]
        default: throw BehaviorError("`\(message)` takes named arguments, not `\(arguments.inline)`.")
        }
        let signature = signature.written
        if let extra = given.keys.sorted().first(where: { name in !parameters.contains { $0.name == name } }) {
            throw BehaviorError("`\(message)` doesn't take `\(extra)`. It's `\(signature)`.")
        }
        var bound: [String: JSONValue] = [:]
        for parameter in parameters {
            guard let value = given[parameter.name], value != .null else {
                throw BehaviorError("`\(message)` needs `\(parameter.name)`. It's `\(signature)`.")
            }
            guard parameter.type.accepts(value) else {
                throw BehaviorError("`\(parameter.name)` is `\(value.inline)`, but `\(message)` takes \(parameter.type.withArticle) there.")
            }
            bound[parameter.name] = value
        }
        return bound
    }
}

/// What a clause can see while it runs: its arguments, and the fields as they are so far.
private struct Scope {
    let parameters: [String: JSONValue]
    var fields: [String: JSONValue]
    /// The object's own reference is filled in by whoever sends; here it stands as itself.
    static let me: JSONValue = ["self": true]

    func resolve(_ value: Behavior.Value) throws(BehaviorError) -> JSONValue {
        switch value {
        case .literal(let json): return json
        case .parameter(let name): return parameters[name] ?? .null
        case .field(let name): return fields[name] ?? .null
        case .me: return Self.me
        case .text(let parts):
            var text = ""
            for part in parts {
                switch part {
                case .text(let piece): text += piece
                case .value(let value): text += try resolve(value).inline
                }
            }
            return .string(text)
        }
    }

    func holds(_ condition: Behavior.Guard) throws(BehaviorError) -> Bool {
        let left = try resolve(condition.left)
        let right = try condition.right.map { value throws(BehaviorError) in try resolve(value) } ?? .null
        switch condition.comparison {
        case .equal: return left.sameValue(as: right)
        case .notEqual: return !left.sameValue(as: right)
        case .lessThan, .atMost, .greaterThan, .atLeast:
            guard let a = left.numeric, let b = right.numeric else {
                throw BehaviorError("It can't compare `\(left.inline)` with `\(right.inline)`: `\(condition.comparison.rawValue)` compares numbers.")
            }
            switch condition.comparison {
            case .lessThan: return a < b
            case .atMost: return a <= b
            case .greaterThan: return a > b
            default: return a >= b
            }
        case .contains:
            switch left {
            case .array(let items): return items.contains { $0.sameValue(as: right) }
            case .string(let text): return right.string.map(text.contains) ?? false
            default: return false
            }
        case .isEmpty, .isNotEmpty:
            let empty: Bool =
                switch left {
                case .array(let items): items.isEmpty
                case .string(let text): text.isEmpty
                case .null: true
                default: false
                }
            return condition.comparison == .isEmpty ? empty : !empty
        }
    }

    /// A guard that didn't hold, with the values it saw: `total < approveBelow (80 < 50)`.
    func describe(_ condition: Behavior.Guard) -> String {
        func text(_ value: Behavior.Value) -> String {
            switch value {
            case .literal(let json): json.inline
            case .parameter(let name), .field(let name): name
            case .me: "self"
            case .text: "text"
            }
        }
        let seen = [condition.left, condition.right].compactMap { $0 }.compactMap { try? resolve($0).inline }
        let written = [text(condition.left), condition.comparison.rawValue] + (condition.right.map { [text($0)] } ?? [])
        return "`\(written.joined(separator: " "))` was false (\(seen.joined(separator: ", ")))"
    }
}

extension JSONValue {
    /// The value on one line, as YAML's flow style writes it: `[1, 2]`, `{number: 2}`, `text`.
    public var inline: String {
        switch self {
        case .null: "null"
        case .bool(let bool): "\(bool)"
        case .integer(let integer): "\(integer)"
        case .unsignedInteger(let integer): "\(integer)"
        case .number(let number): number.rounded() == number && abs(number) < 1e15 ? "\(Int64(number))" : "\(number)"
        case .string(let text): text
        case .array(let items): "[\(items.map(\.inline).joined(separator: ", "))]"
        case .object(let members): "{\(members.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.inline)" }.joined(separator: ", "))}"
        }
    }

    var numeric: Double? {
        switch self {
        case .integer(let integer): Double(integer)
        case .unsignedInteger(let integer): Double(integer)
        case .number(let number): number
        default: nil
        }
    }

    var isNumeric: Bool { numeric != nil }

    var negated: JSONValue? {
        switch self {
        case .integer(let integer): .integer(-integer)
        case .unsignedInteger(let integer): .number(-Double(integer))
        case .number(let number): .number(-number)
        default: nil
        }
    }

    var string: String? {
        if case .string(let text) = self { text } else { nil }
    }

    /// Equal as values: `2` and `2.0` are the same number.
    func sameValue(as other: JSONValue) -> Bool {
        if let a = numeric, let b = other.numeric { return a == b }
        return self == other
    }

    /// The sum of two numbers, a whole number when both are.
    func adding(_ other: JSONValue) -> JSONValue? {
        switch (self, other) {
        case (.integer(let a), .integer(let b)): return .integer(a + b)
        default:
            guard let a = numeric, let b = other.numeric else { return nil }
            return .number(a + b)
        }
    }
}
