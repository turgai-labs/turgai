import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax
import Yams

/// A kind of object as a person reads and edits it, next to its code: what it holds, the checks
/// that always hold, the states it can be in, and how it handles each message, as rules where its
/// code reads as rules and as code where it doesn't. It's read from a ``Script``'s Swift, as YAML
/// to show; edited, it's rendered as Swift, which becomes the script. The script is the kind: this
/// is a view of it.
public struct ObjectSource: Codable, Sendable, Equatable {
    /// Something it holds, as a Swift binding: `approveBelow: Double = 500`.
    public struct Datum: Codable, Sendable, Equatable {
        let name: String
        /// `let`: a setting, kept as it starts.
        let constant: Bool
        let type: String?
        let start: String

        var written: String { "\(name)\(type.map { ": \($0)" } ?? "") = \(start)" }
    }

    /// How it handles one message.
    public enum Handling: Codable, Sendable, Equatable {
        /// Erlang's clauses: the first whose `when` holds runs its `do`; one with no `when` takes
        /// the rest.
        case rules([Clause])
        /// Anything that isn't rules: the method's body as written.
        case code(String)
    }

    public struct Clause: Codable, Sendable, Equatable {
        /// Swift's condition, such as `total < approveBelow` or `let index = items.firstIndex(of: item)`.
        let when: String?
        /// Swift statements, in order.
        let actions: [String]
    }

    public struct Message: Codable, Sendable, Equatable {
        /// `tripPlanned(trip: String, total: Double) -> String`
        let signature: String
        let handling: Handling

        var name: String { String(signature.prefix { $0 != "(" }) }
    }

    /// A state it can be in, and the messages it takes there, as SCXML's transitions of a state.
    public struct State: Codable, Sendable, Equatable {
        let name: String
        /// What it holds while in it, as an enum case's associated values: `trip: String, total: Double`.
        var values: String? = nil
        public let receive: [Message]

        /// Its associated values' labels, which a case binds by name.
        var labels: [String] {
            (values ?? "").split(separator: ",").map { String($0.split(separator: ":").first ?? "").trimmingCharacters(in: .whitespaces) }
        }

        var written: String { name + (values.map { "(\($0))" } ?? "") }
    }

    public let object: String
    public let data: [Datum]
    /// Swift conditions that hold after every message, as Pkl's constraints: a message that would
    /// break one changes nothing.
    public let checks: [String]
    /// The state it starts in, when it has states.
    public let initial: String?
    public let states: [State]
    /// Messages it takes in every state.
    let receive: [Message]
    /// Members that aren't data or messages, such as private methods, as Swift.
    public let helpers: String?

    /// Every message it takes, in any state, in the order first written.
    public var messages: [String] {
        var names: [String] = []
        for message in receive + states.flatMap(\.receive) where !names.contains(message.name) { names.append(message.name) }
        return names
    }

    /// Whether it takes `message` in `state`.
    public func takes(_ message: String, in state: String?) -> Bool {
        if receive.contains(where: { $0.name == message }) { return true }
        guard let state else { return states.isEmpty }
        return states.first { $0.name == state }?.receive.contains { $0.name == message } ?? false
    }

    /// The same kind with other starting values, as a Pkl `amends`: only values it has can be
    /// given, and checks are kept.
    public func amended(_ values: [(String, String)]) throws(CodeProblem) -> ObjectSource {
        var data = self.data
        for (name, start) in values {
            guard let index = data.firstIndex(where: { $0.name == name }) else {
                throw CodeProblem("\(object) has no `\(name)`. It has \(data.map { "`\($0.name)`" }.joined(separator: ", ")).")
            }
            data[index] = Datum(name: name, constant: data[index].constant, type: data[index].type, start: start)
        }
        return ObjectSource(
            object: object, data: data, checks: checks, initial: initial, states: states, receive: receive, helpers: helpers)
    }
}

// MARK: - Swift to config

extension ObjectSource {
    /// The kind an actor's code defines; a class reads the same. Code outside the actor is left
    /// out: an object is its actor. Its states are an `enum State` held in `var state`, and a
    /// method that switches on `state` handles its message state by state.
    public init(swift code: String, type: String) throws(CodeProblem) {
        let file = Parser.parse(source: code)
        // Code that isn't Swift is never kept, whatever an interpreter would make of it.
        if let error = ParseDiagnosticsGenerator.diagnostics(for: file).first(where: { $0.diagMessage.severity == .error }) {
            let line = SourceLocationConverter(fileName: "", tree: file).location(for: error.position).line
            throw CodeProblem(line: line, error.message)
        }
        let declared: [(name: String, members: MemberBlockSyntax)] = file.statements.compactMap { statement in
            if let actor = statement.item.as(ActorDeclSyntax.self) { return (actor.name.text, actor.memberBlock) }
            if let type = statement.item.as(ClassDeclSyntax.self) { return (type.name.text, type.memberBlock) }
            return nil
        }
        guard let actor = declared.first(where: { $0.name == type }) else {
            throw CodeProblem("There's no `actor \(type)`.")
        }
        let members = actor.members.members.map(\.decl)
        // Its states: an `enum State` of plain cases, in the actor or beside it.
        var stateNames: [String] = []
        var stateValues: [String: String] = [:]
        let enums = members.compactMap { $0.as(EnumDeclSyntax.self) } + file.statements.compactMap { $0.item.as(EnumDeclSyntax.self) }
        if let states = enums.first(where: { $0.name.text == "State" }) {
            for element in states.memberBlock.members.compactMap({ $0.decl.as(EnumCaseDeclSyntax.self) }).flatMap(\.elements) {
                stateNames.append(element.name.text)
                if let parameters = element.parameterClause?.parameters { stateValues[element.name.text] = parameters.trimmedDescription }
            }
        }
        var data: [Datum] = []
        var checks: [String] = []
        var initial: String?
        var receive: [Message] = []
        var byState: [String: [Message]] = [:]
        var helpers: [String] = []
        let types = Set(members.compactMap { $0.as(EnumDeclSyntax.self)?.name.text ?? $0.as(StructDeclSyntax.self)?.name.text })
        for declaration in members {
            if let states = declaration.as(EnumDeclSyntax.self), states.name.text == "State", !stateNames.isEmpty { continue }
            // Another object it's given no value for is one it talks to, found by its name, as
            // Swift declares a dependency: not data.
            if let variable = declaration.as(VariableDeclSyntax.self), variable.bindings.allSatisfy({ binding in
                guard binding.initializer == nil, let type = binding.typeAnnotation?.type, !type.is(OptionalTypeSyntax.self) else { return false }
                return ValueKind(type, declared: types) == .object
            }) {
                continue
            }
            if let variable = declaration.as(VariableDeclSyntax.self),
                variable.bindings.allSatisfy({ $0.accessorBlock == nil && ($0.initializer != nil || Self.optional($0.typeAnnotation?.type)) }),
                !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
            {
                for binding in variable.bindings {
                    let name = binding.pattern.trimmedDescription
                    // An optional with no value starts as `nil`, as in Swift.
                    let start = binding.initializer?.value.trimmedDescription ?? "nil"
                    if name == "state", !stateNames.isEmpty {
                        initial = String(start.split(separator: ".").last ?? "")
                        continue
                    }
                    data.append(
                        Datum(
                            name: name, constant: variable.bindingSpecifier.tokenKind == .keyword(.let),
                            type: binding.typeAnnotation?.type.trimmedDescription, start: start))
                }
            } else if let function = declaration.as(FunctionDeclSyntax.self), function.name.text == "_check", let body = function.body {
                checks = Self.checks(in: body.statements)
            } else if let function = declaration.as(FunctionDeclSyntax.self),
                !function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate) }),
                let body = function.body
            {
                let signature = function.name.text + function.signature.trimmedDescription
                if !stateNames.isEmpty, let cases = Self.stateSwitch(body.statements, values: stateValues) {
                    var covered: Set<String> = []
                    var otherwise: Handling?
                    for (names, handling) in cases {
                        guard let names else {
                            otherwise = handling
                            continue
                        }
                        for name in names {
                            covered.insert(name)
                            if let handling { byState[name, default: []].append(Message(signature: signature, handling: handling)) }
                        }
                    }
                    // `default` takes the states no case names, unless it refuses.
                    if let otherwise {
                        for name in stateNames where !covered.contains(name) {
                            byState[name, default: []].append(Message(signature: signature, handling: otherwise))
                        }
                    }
                } else {
                    receive.append(Message(signature: signature, handling: Self.handling(body.statements)))
                }
            } else {
                helpers.append(declaration.trimmedDescription)
            }
        }
        // Settings come first, as the YAML has them.
        self.init(
            object: type, data: data.filter(\.constant) + data.filter { !$0.constant }, checks: checks,
            initial: stateNames.isEmpty ? nil : initial ?? stateNames.first,
            states: stateNames.map { State(name: $0, values: stateValues[$0], receive: byState[$0] ?? []) }, receive: receive,
            helpers: helpers.isEmpty ? nil : helpers.joined(separator: "\n\n"))
    }

    private static func optional(_ type: TypeSyntax?) -> Bool {
        guard let type else { return false }
        return type.is(OptionalTypeSyntax.self) || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self)
    }

    private static func handling(_ statements: CodeBlockItemListSyntax) -> Handling {
        (try? rules(of: statements)).map(Handling.rules) ?? .code(dedented(statements))
    }

    /// A body that's one `switch state`: each case's state names (`nil` for `default`) and how it
    /// handles the message there (`nil` when it refuses, with `fatalError`).
    private static func stateSwitch(_ statements: CodeBlockItemListSyntax, values: [String: String]) -> [([String]?, Handling?)]? {
        guard statements.count == 1, let item = statements.first else { return nil }
        let found = item.item.as(ExpressionStmtSyntax.self)?.expression.as(SwitchExprSyntax.self) ?? item.item.as(SwitchExprSyntax.self)
        guard let switchState = found, ["state", "self.state"].contains(switchState.subject.trimmedDescription) else { return nil }
        var result: [([String]?, Handling?)] = []
        for element in switchState.cases {
            guard let switchCase = element.as(SwitchCaseSyntax.self) else { return nil }
            let body = switchCase.statements
            let only = body.count == 1 ? body.first!.item.trimmedDescription : nil
            let handling: Handling? =
                only?.hasPrefix("fatalError") == true ? nil
                : only == "break" ? .rules([Clause(when: nil, actions: [])]) : Self.handling(body)
            switch switchCase.label {
            case .default: result.append((nil, handling))
            case .case(let label):
                var names: [String] = []
                for item in label.caseItems {
                    guard let pattern = item.pattern.as(ExpressionPatternSyntax.self)?.expression else { return nil }
                    if let member = pattern.as(MemberAccessExprSyntax.self) {
                        names.append(member.declName.baseName.text)
                    } else if let call = pattern.as(FunctionCallExprSyntax.self), let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                        // `.waitingForOwner(let trip, let total)`: its values, bound by their labels.
                        let name = member.declName.baseName.text
                        let bound = call.arguments.map { $0.expression.trimmedDescription.replacingOccurrences(of: "let ", with: "") }
                        let labels = State(name: name, values: values[name], receive: []).labels
                        guard bound == labels else { return nil }
                        names.append(name)
                    } else {
                        return nil
                    }
                }
                result.append((names, handling))
            }
        }
        return result
    }

    /// `if !(condition) { return "condition" }`, for each check.
    private static func checks(in statements: CodeBlockItemListSyntax) -> [String] {
        statements.compactMap { item in
            guard let chain = ifChain(item), let condition = chain.conditions.first,
                case .expression(let expression) = condition.condition,
                let negated = expression.as(PrefixOperatorExprSyntax.self),
                let inner = negated.expression.as(TupleExprSyntax.self)
            else { return nil }
            return inner.elements.trimmedDescription
        }
    }

    struct NotRules: Error {
        let reason: String
    }

    /// A body as rules: `guard`s first, then actions, at most one `if … else if … else` chain,
    /// and actions after it. Actions before the chain run in every clause, and so do actions
    /// after it.
    static func rules(of statements: CodeBlockItemListSyntax) throws(NotRules) -> [Clause] {
        var early: [Clause] = []
        var before: [String] = []
        var chain: [Clause]?
        var after: [String] = []
        for item in statements {
            if let guardStatement = item.item.as(GuardStmtSyntax.self) {
                guard before.isEmpty, chain == nil, guardStatement.conditions.count == 1,
                    case .expression(let condition) = guardStatement.conditions.first!.condition
                else { throw NotRules(reason: "guard") }
                early.append(Clause(when: "!(\(condition.trimmedDescription))", actions: try actions(guardStatement.body.statements)))
            } else if let found = ifChain(item) {
                guard chain == nil else { throw NotRules(reason: "two ifs") }
                chain = try clauses(of: found)
            } else if chain == nil {
                before.append(try action(item))
            } else {
                after.append(try action(item))
            }
        }
        let body = (chain ?? [Clause(when: nil, actions: [])]).map { Clause(when: $0.when, actions: before + $0.actions + after) }
        return early + body
    }

    fileprivate static func ifChain(_ item: CodeBlockItemSyntax) -> IfExprSyntax? {
        if let expression = item.item.as(ExpressionStmtSyntax.self) { return expression.expression.as(IfExprSyntax.self) }
        return item.item.as(IfExprSyntax.self)
    }

    private static func clauses(of chain: IfExprSyntax) throws(NotRules) -> [Clause] {
        var result = [Clause(when: chain.conditions.trimmedDescription, actions: try actions(chain.body.statements))]
        switch chain.elseBody {
        case .ifExpr(let next)?: result += try clauses(of: next)
        case .codeBlock(let block)?: result.append(Clause(when: nil, actions: try actions(block.statements)))
        case nil: result.append(Clause(when: nil, actions: []))
        }
        return result
    }

    private static func actions(_ statements: CodeBlockItemListSyntax) throws(NotRules) -> [String] {
        var result: [String] = []
        for item in statements { result.append(try action(item)) }
        return result
    }

    /// One statement with no statement nested in it: an expression, a `return`, or a local
    /// `let`/`var`. A closure inside an expression is part of the expression.
    private static func action(_ item: CodeBlockItemSyntax) throws(NotRules) -> String {
        let node = item.item
        if ifChain(item) != nil { throw NotRules(reason: "nested if") }
        if let statement = node.as(ExpressionStmtSyntax.self) {
            if statement.expression.is(SwitchExprSyntax.self) { throw NotRules(reason: "switch") }
            return statement.trimmedDescription
        }
        if node.is(ReturnStmtSyntax.self) || node.is(ExprSyntax.self) { return node.trimmedDescription }
        if let variable = node.as(VariableDeclSyntax.self), variable.bindings.allSatisfy({ $0.accessorBlock == nil }) {
            return node.trimmedDescription
        }
        throw NotRules(reason: String(describing: node.syntaxNodeType))
    }

    /// Statements as written, without the indent they had in the method.
    private static func dedented(_ statements: CodeBlockItemListSyntax) -> String {
        let lines = statements.description.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Config to Swift

extension ObjectSource {
    public var swift: String {
        var lines = ["actor \(object) {"]
        if let initial {
            lines += ["    enum State {"] + states.map { "        case \($0.written)" } + ["    }", ""]
            lines.append("    var state: State = .\(initial)")
        }
        for datum in data {
            lines.append("    \(datum.constant ? "let" : "var") \(datum.written)")
        }
        for message in receive {
            lines.append("")
            lines.append("    func \(message.signature) {")
            lines += Self.render(message.handling, at: 8)
            lines.append("    }")
        }
        // A message taken in some states: one method, switching on the state it's in.
        var signatures: [String] = []
        for message in states.flatMap(\.receive) where !signatures.contains(message.signature) { signatures.append(message.signature) }
        for signature in signatures {
            lines.append("")
            lines.append("    func \(signature) {")
            lines.append("        switch state {")
            var refused = false
            for state in states {
                guard let message = state.receive.first(where: { $0.signature == signature }) else {
                    refused = true
                    continue
                }
                let bound = state.values == nil ? "" : "(" + state.labels.map { "let \($0)" }.joined(separator: ", ") + ")"
                lines.append("        case .\(state.name)\(bound):")
                let body = Self.render(message.handling, at: 12)
                lines += body.isEmpty ? ["            break"] : body
            }
            if refused {
                lines.append("        default:")
                lines.append("            fatalError(\"not taken in this state\")")
            }
            lines.append("        }")
            lines.append("    }")
        }
        if !checks.isEmpty {
            lines.append("")
            lines.append("    func _check() -> String {")
            for check in checks {
                lines.append("        if !(\(check)) { return \(check.debugDescription) }")
            }
            lines.append("        return \"\"")
            lines.append("    }")
        }
        if let helpers {
            lines.append("")
            lines += Self.indented(helpers, by: 4)
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func render(_ handling: Handling, at indent: Int) -> [String] {
        switch handling {
        case .code(let code): return indented(code, by: indent)
        case .rules(let clauses): return render(clauses, at: indent)
        }
    }

    private static func render(_ clauses: [Clause], at indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        let guarded = clauses.filter { $0.when != nil }
        let rest = clauses.last { $0.when == nil }?.actions ?? []
        guard !guarded.isEmpty else { return rest.flatMap { indented($0, by: indent) } }
        var lines: [String] = []
        for (index, clause) in guarded.enumerated() {
            lines.append(pad + (index == 0 ? "if " : "} else if ") + clause.when! + " {")
            lines += clause.actions.flatMap { indented($0, by: indent + 4) }
        }
        if !rest.isEmpty {
            lines.append(pad + "} else {")
            lines += rest.flatMap { indented($0, by: indent + 4) }
        }
        lines.append(pad + "}")
        return lines
    }

    fileprivate static func indented(_ text: String, by spaces: Int) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { String(repeating: " ", count: spaces) + $0 }
    }
}

// MARK: - YAML

extension ObjectSource {
    /// The kind as YAML: `settings` and `data` as Swift bindings without `var`, `checks`, `talks
    /// to`, the state it starts in, `receive` for every state and `states` for each, each
    /// message's rules as `when`/`do` and `otherwise`, or its `code`.
    public var yaml: String {
        get throws {
            var root: [(Node, Node)] = [(Node("object"), Node(object))]
            let settings = data.filter(\.constant), held = data.filter { !$0.constant }
            if !settings.isEmpty { root.append((Node("settings"), Self.block(settings.map(\.written)))) }
            if !held.isEmpty { root.append((Node("data"), Self.block(held.map(\.written)))) }
            if !checks.isEmpty { root.append((Node("checks"), Node(checks.map { Node($0) }))) }
            if let initial { root.append((Node("state"), Node(initial))) }
            if !receive.isEmpty { root.append((Node("receive"), Self.node(receive))) }
            if !states.isEmpty {
                root.append((Node("states"), Node.mapping(Node.Mapping(states.map { (Node($0.written), Self.node($0.receive)) }))))
            }
            if let helpers { root.append((Node("helpers"), Node(helpers + "\n", Tag(.str), .literal))) }
            return try Yams.serialize(node: Node.mapping(Node.Mapping(root)), width: -1, allowUnicode: true)
        }
    }

    private static func node(_ messages: [Message]) -> Node {
        Node.mapping(Node.Mapping(messages.map { message in
            let value: Node
            switch message.handling {
            case .code(let code):
                value = Node.mapping(Node.Mapping([(Node("code"), Node(code + "\n", Tag(.str), .literal))]))
            case .rules(let clauses) where clauses.count == 1 && clauses[0].when == nil:
                value = block(clauses[0].actions)
            case .rules(let clauses):
                value = Node(clauses.map { clause in
                    let actions = block(clause.actions)
                    guard let when = clause.when else { return Node.mapping(Node.Mapping([(Node("otherwise"), actions)])) }
                    return Node.mapping(Node.Mapping([(Node("when"), Node(when)), (Node("do"), actions)]))
                })
            }
            return (Node(message.signature), value)
        }))
    }

    /// Lines as a literal block: Swift as written, with nothing quoted.
    private static func block(_ lines: [String]) -> Node {
        lines.isEmpty ? Node("") : Node(lines.joined(separator: "\n") + "\n", Tag(.str), .literal)
    }

    /// A literal block's statements, each as Swift reads it.
    private static func statements(_ node: Node?) -> [String] {
        guard let text = node?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return Parser.parse(source: text).statements.map(\.trimmedDescription)
    }

    /// Bindings without `var`, one starting at each unindented line.
    private static func bindings(_ node: Node?, constant: Bool) throws(CodeProblem) -> [Datum] {
        guard let text = node?.string else { return [] }
        var declarations: [String] = []
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if line.first == " ", !declarations.isEmpty { declarations[declarations.count - 1] += "\n" + line } else { declarations.append(String(line)) }
        }
        var result: [Datum] = []
        for declaration in declarations {
            guard let variable = Parser.parse(source: "var " + declaration).statements.first?.item.as(VariableDeclSyntax.self),
                let binding = variable.bindings.first, let start = binding.initializer?.value
            else { throw CodeProblem("`\(declaration)` isn't `name: Type = value`.") }
            result.append(
                Datum(
                    name: binding.pattern.trimmedDescription, constant: constant, type: binding.typeAnnotation?.type.trimmedDescription,
                    start: start.trimmedDescription))
        }
        return result
    }

    private static func messages(_ node: Node?) -> [Message] {
        (node?.mapping ?? Node.Mapping([])).map { key, value in
            let handling: Handling
            if let code = value["code"]?.string {
                handling = .code(code.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if let items = value.sequence {
                handling = .rules(items.map { item in
                    if let otherwise = item["otherwise"] { return Clause(when: nil, actions: statements(otherwise)) }
                    return Clause(when: item["when"]?.string, actions: statements(item["do"]))
                })
            } else {
                handling = .rules([Clause(when: nil, actions: statements(value))])
            }
            return Message(signature: key.string!, handling: handling)
        }
    }

    public init(yaml text: String) throws(CodeProblem) {
        let root = try Self.compose(text)
        guard let object = root["object"]?.string else { throw CodeProblem("It needs `object`, its name.") }
        self.init(
            object: object,
            data: try Self.bindings(root["settings"], constant: true) + Self.bindings(root["data"], constant: false),
            checks: root["checks"]?.sequence?.compactMap(\.string) ?? [], initial: root["state"]?.string,
            states: (root["states"]?.mapping ?? Node.Mapping([])).map { key, value in
                let written = key.string!
                let name = String(written.prefix { $0 != "(" })
                let values = written.contains("(") ? String(written.dropFirst(name.count + 1).dropLast()) : nil
                return State(name: name, values: values, receive: Self.messages(value))
            },
            receive: Self.messages(root["receive"]),
            helpers: root["helpers"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func compose(_ text: String) throws(CodeProblem) -> Node {
        do {
            guard let node = try Yams.compose(yaml: text) else { throw CodeProblem("The file is empty.") }
            return node
        } catch let problem as CodeProblem {
            throw problem
        } catch {
            throw CodeProblem("\(error)")
        }
    }
}
