// Changing a spec a step at a time, as typed values: what a draft does as it's defined.

extension Behavior.Written {
    /// No behavior yet, and nothing held: where every new object starts, the way an actor can
    /// start out handling nothing (Akka's `Behaviors.empty`).
    public static let empty = Behavior.Written(fields: [], receive: [])

    /// Holding `name`, starting as `start`, in place of a field of that name.
    public func holding(_ name: String, start: Value) -> Behavior.Written {
        Behavior.Written(fields: fields.filter { $0.name != name } + [Field(name: name, start: start)], receive: receive)
    }

    /// Handling `message`: a clause for it, doing nothing yet, unless it has one.
    public func handling(_ message: String) -> Behavior.Written {
        guard !receive.contains(where: { $0.on == message }) else { return self }
        return Behavior.Written(fields: fields, receive: receive + [Clause(on: message, parameters: nil, when: nil, actions: [])])
    }

    /// `message` given `parameter`, in each clause handling it.
    public func taking(_ parameter: Parameter, in message: String) -> Behavior.Written {
        let receive = handling(message).receive.map { clause -> Clause in
            guard clause.on == message, !(clause.parameters ?? []).contains(where: { $0.name == parameter.name }) else { return clause }
            return Clause(on: clause.on, parameters: (clause.parameters ?? []) + [parameter], when: clause.when, actions: clause.actions)
        }
        return Behavior.Written(fields: fields, receive: receive)
    }

    /// Doing `action` when `message` arrives, after what it does already.
    public func doing(_ action: Action, on message: String) -> Behavior.Written {
        var added = false
        let receive = handling(message).receive.map { clause -> Clause in
            guard !added, clause.on == message, clause.when == nil else { return clause }
            added = true
            return Clause(on: clause.on, parameters: clause.parameters, when: clause.when, actions: clause.actions + [action])
        }
        return Behavior.Written(fields: fields, receive: receive)
    }

    /// Receiving with `clause` too, the way an Erlang `receive` tries its clauses: it replaces a
    /// clause for the same message with the same guard; otherwise it's a clause of its own, after
    /// the message's other specific clauses when it has a guard, last when it hasn't. A
    /// clause written without parameters takes the message's, from a clause it has for it or
    /// `message`, what another object sends.
    public func receiving(_ clause: Clause, as message: Signature? = nil) -> Behavior.Written {
        let parameters =
            clause.parameters
            ?? receive.first(where: { $0.on == clause.on })?.parameters
            ?? message.map { $0.parameters.map { Parameter(name: $0.name, type: Kind($0.type), like: nil) } }
        let clause = Clause(on: clause.on, parameters: parameters, when: clause.when, actions: clause.actions)
        var receive = receive
        if let index = receive.firstIndex(where: { $0.on == clause.on && $0.when == clause.when }) {
            // Written again, a clause is written anew, as Erlang has no adding to one.
            receive[index] = Clause(on: clause.on, parameters: receive[index].parameters, when: clause.when, actions: clause.actions)
        } else if clause.when != nil, let general = receive.firstIndex(where: { $0.on == clause.on && $0.when == nil }) {
            // Specific clauses keep the order they're defined in, as Erlang's source order, and
            // all come before the general one, which would otherwise take every message first.
            receive.insert(clause, at: general)
        } else {
            receive.append(clause)
        }
        return Behavior.Written(fields: fields, receive: receive)
    }
}

extension Behavior.Written.Clause {
    /// A clause for `message`, taking `parameters` (or, with none, the message's as the spec has
    /// them), when every guard holds, doing `actions`.
    public static func on(
        _ message: String, taking parameters: [Behavior.Written.Parameter]?, when guards: [Behavior.Written.Guard]?,
        doing actions: [Behavior.Written.Action]
    ) -> Self {
        Self(on: message, parameters: parameters, when: guards, actions: actions)
    }
}

extension Behavior.Written.Guard {
    /// `left comparison right`, such as `total <= limit`.
    public static func comparing(_ left: Behavior.Written.Value, _ comparison: Behavior.Written.Comparison, _ right: Behavior.Written.Value) -> Self {
        Self(left: left, comparison: comparison, right: right)
    }
}

extension Behavior.Written.Parameter {
    public static func named(_ name: String, _ type: Behavior.Written.Kind) -> Self {
        Self(name: name, type: type, like: nil)
    }
}

extension Behavior.Written.Action {
    /// Sends `message` to the object `object`, passing each of its parameters as the value of the
    /// same name, such as `shop.refundApproved(order)`.
    public static func telling(_ object: String, _ message: Signature) -> Self {
        .send(
            message: message.name, to: .object(object),
            arguments: message.parameters.map { Behavior.Written.Argument(name: $0.name, value: .name($0.name)) })
    }
}

extension Behavior.Written.Kind {
    /// How a parameter of this type is written: an object of any kind is an object.
    init(_ type: ValueType) {
        switch type {
        case .string: self = .string
        case .integer: self = .integer
        case .number: self = .number
        case .boolean: self = .boolean
        case .list: self = .list
        case .object, .like: self = .object
        }
    }
}

extension Behavior.Written.Comparison {
    /// How it's written in a rule: `<=`, `contains`, `is empty`.
    public var symbol: String {
        switch self {
        case .lessThan: "<"
        case .atMost: "<="
        case .greaterThan: ">"
        case .atLeast: ">="
        case .equal: "=="
        case .notEqual: "!="
        case .contains: "contains"
        case .isEmpty: "is empty"
        case .isNotEmpty: "is not empty"
        }
    }
}

extension Behavior.Written {
    /// Its rules, each named by its event and its condition, such as `refundRequested if total <=
    /// limit`: one clause each, since the same event and condition again replaces it.
    public var rules: [String] {
        receive.map(\.rule)
    }

    /// Without the rule named `rule`.
    public func removing(rule: String) -> Behavior.Written {
        Behavior.Written(fields: fields, receive: receive.filter { $0.rule != rule })
    }
}

extension Behavior.Written.Clause {
    /// `refundRequested if total <= limit`, or `addCup`.
    public var rule: String {
        guard let when, !when.isEmpty else { return on }
        return on + " if " + when.map { Behavior.written($0) }.joined(separator: " and ")
    }
}

extension Behavior.Written {
    /// One change to a spec, as a value: what a step does to an object, journaled and compared
    /// like any other value, and applied by ``applying(_:)``.
    public enum Edit: Sendable, Equatable {
        /// Holding a field, starting as given, in place of one of that name.
        case hold(String, start: Value)
        /// Receiving with a clause, as ``receiving(_:as:)`` places it. `taking` is what an event
        /// of its own is given, added to every clause for it; `message` is what another object
        /// sends, for a clause written on its name alone.
        case receive(Clause, taking: [Parameter], message: Signature?)
        /// All the clauses for one event, in the order given. Replaces that event at once.
        case replaceEvent(String, clauses: [Clause], taking: [Parameter], message: Signature?)
        /// Without the rule of that name.
        case remove(rule: String)
    }

    /// The spec with `edit` applied: a reducer, `spec.applying(edit)`.
    public func applying(_ edit: Edit) -> Behavior.Written {
        switch edit {
        case .hold(let field, let start):
            return holding(field, start: start)
        case .remove(let rule):
            return removing(rule: rule)
        case .receive(let clause, let taking, let message):
            guard !taking.isEmpty, receive.contains(where: { $0.on == clause.on }) else {
                let parameters = taking.isEmpty ? clause.parameters : taking
                return receiving(.on(clause.on, taking: parameters, when: clause.when, doing: clause.actions), as: message)
            }
            // An event of its own already handled takes what the new clause is given, in each clause.
            return taking.reduce(self) { $0.taking($1, in: clause.on) }.receiving(clause, as: message)
        case .replaceEvent(let event, let clauses, let taking, let message):
            let parameters =
                message.map { $0.parameters.map { Parameter(name: $0.name, type: Kind($0.type), like: nil) } }
                ?? taking
            let replacements = clauses.map {
                Clause(on: event, parameters: parameters, when: $0.when, actions: $0.actions)
            }
            var result = receive
            let insertion = result.firstIndex { $0.on == event } ?? result.endIndex
            result.removeAll { $0.on == event }
            result.insert(contentsOf: replacements, at: min(insertion, result.endIndex))
            return Behavior.Written(fields: fields, receive: result)
        }
    }
}
