import SwiftParser
import SwiftSyntax

extension RuntimeMacros {
    /// What's wrong with how `script` uses the runtime's macros, which Swift doesn't know: each
    /// `@Subscribed` property holds an object that announces events, and its actor handles at least
    /// one of them, each with a function taking what its event does.
    static func problems(in script: Script) -> [CodeProblem] {
        let file = Parser.parse(source: script.code)
        let lines = SourceLocationConverter(fileName: "", tree: file)
        func line(_ node: some SyntaxProtocol) -> Int { lines.location(for: node.positionAfterSkippingLeadingTrivia).line }
        guard let actor = file.statements.lazy.compactMap({ $0.item.as(ActorDeclSyntax.self) }).first(where: { $0.name.text == script.type })
        else { return [] }
        let objects = Dictionary(script.uses.interface.actors(events: [event]).map { ($0.name, $0) }) { first, _ in first }
        let methods = actor.memberBlock.members.compactMap { $0.decl.as(FunctionDeclSyntax.self) }
        var problems: [CodeProblem] = []
        for member in actor.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self), ObjectShape.carries(variable.attributes, subscribed),
                let binding = variable.bindings.first
            else { continue }
            // What it follows is an object that exists, which it holds: as written, or as made.
            let written = binding.typeAnnotation.map { ($0.type.as(OptionalTypeSyntax.self)?.wrappedType ?? $0.type).trimmedDescription }
            let made = binding.initializer?.value.as(FunctionCallExprSyntax.self)?.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
            guard let type = [written, made].compactMap({ $0 }).first(where: { objects[$0] != nil }), let followed = objects[type] else {
                let held = written ?? binding.initializer?.value.trimmedDescription ?? binding.pattern.trimmedDescription
                problems.append(CodeProblem(
                    line: line(variable), span: variable.trimmedDescription,
                    "@\(subscribed) should hold the object that sends the events, while `\(held)` is no object"))
                continue
            }
            let events = Dictionary(followed.events.map { (DynamicObject.handler(for: $0.key), $0.value) }) { first, _ in first }
            guard !events.isEmpty else { continue }
            let object = script.uses.names.filter { $0.value == type }.map(\.key).sorted().first ?? type
            let handling = methods.filter { events[$0.name.text] != nil }
            guard !handling.isEmpty else {
                let listed = events.sorted { $0.key < $1.key }.map { Self.written($0.key, $0.value) }.joined(separator: ", ")
                problems.append(CodeProblem(line: line(variable), span: variable.trimmedDescription, "no function handles the events of \(object): \(listed)"))
                continue
            }
            for method in handling {
                guard let event = events[method.name.text] else { continue }
                let given = method.signature.parameterClause.parameters.map { $0.firstName.text == "_" ? nil : $0.firstName.text }
                if given != event.parameters.map(\.label) {
                    problems.append(CodeProblem(
                        line: line(method.name), span: "func \(method.name.text)\(method.signature.parameterClause.trimmedDescription)",
                        "the event of \(object) calls \(Self.written(method.name.text, event))"))
                }
            }
        }
        return problems
    }

    /// An event's handler as Swift declares it: `onRefundRequested(order: Int)`.
    private static func written(_ name: String, _ method: DeclaredActor.Method) -> String {
        let parameters = method.parameters.map { parameter in
            let called = parameter.label == parameter.name ? parameter.name : "\(parameter.label ?? "_") \(parameter.name)"
            return "\(called): \(parameter.type)"
        }
        return "\(name)(\(parameters.joined(separator: ", ")))"
    }
}
