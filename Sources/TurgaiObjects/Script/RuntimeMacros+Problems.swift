import SwiftParser
import SwiftSyntax

extension RuntimeMacros {
    /// What's wrong with how `script` uses the runtime's macros, which Swift doesn't know: an
    /// `@Event` is a struct or an enum in the actor; each `@Subscribed` property holds an object
    /// that announces events, and its actor handles at least one of them, each with a function
    /// taking its event's value, or it holds a `Schedule` or a `Timer`, and its actor handles it
    /// being due. That it holds one that lasts is the rule for what any property holds.
    static func problems(in script: Script) -> [CodeProblem] {
        let file = Parser.parse(source: script.code)
        let lines = SourceLocationConverter(fileName: "", tree: file)
        func line(_ node: some SyntaxProtocol) -> Int {
            lines.location(for: node.positionAfterSkippingLeadingTrivia).line
        }
        guard
            let actor = file.statements.lazy.compactMap({ $0.item.as(ActorDeclSyntax.self) }).first(where: {
                $0.name.text == script.type
            })
        else { return [] }
        let objects = Dictionary(script.uses.interface.actors(events: [event]).map { ($0.name, $0) }) { first, _ in
            first
        }
        let methods = actor.memberBlock.members.compactMap { $0.decl.as(FunctionDeclSyntax.self) }
        var problems = Self.misplacedEvents(in: file, actor: actor, line: line)
        for member in actor.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                let attribute = subscribedAttribute(in: variable.attributes),
                let binding = variable.bindings.first
            else { continue }
            let written = binding.typeAnnotation.map {
                ($0.type.as(OptionalTypeSyntax.self)?.wrappedType ?? $0.type).trimmedDescription
            }
            let property = binding.pattern.trimmedDescription
            // It follows what its property holds, and is given nothing else.
            if attribute.arguments != nil {
                problems.append(
                    CodeProblem(
                        line: line(variable), span: attribute.trimmedDescription,
                        "@\(subscribed) takes no arguments: it follows what its property holds"))
                continue
            }
            // A schedule or a timer it follows is due as it says: each time, the function named
            // by its property is called, with when it was due.
            if let due = Self.due(written: written, value: binding.initializer?.value) {
                let handler = Schedule.handler(for: property)
                let wanted = "\(handler)(at date: Date)"
                guard let function = methods.first(where: { $0.name.text == handler }) else {
                    problems.append(
                        CodeProblem(
                            line: line(variable), span: variable.trimmedDescription,
                            "no function handles the \(due) `\(property)`: \(wanted)"))
                    continue
                }
                let parameters = function.signature.parameterClause.parameters
                guard parameters.count == 1, let at = parameters.first, at.firstName.text == "at",
                    at.type.trimmedDescription == "Date"
                else {
                    problems.append(
                        CodeProblem(
                            line: line(function.name),
                            span: "func \(handler)\(function.signature.parameterClause.trimmedDescription)",
                            "the \(due) `\(property)` calls \(wanted)"))
                    continue
                }
                continue
            }
            // What it follows is an object that exists, which it holds: as written, or as made.
            let made = binding.initializer?.value.as(FunctionCallExprSyntax.self)?.calledExpression.as(
                DeclReferenceExprSyntax.self)?.baseName.text
            guard let type = [written, made].compactMap({ $0 }).first(where: { objects[$0] != nil }),
                let followed = objects[type]
            else {
                let held =
                    written ?? binding.initializer?.value.trimmedDescription ?? binding.pattern.trimmedDescription
                problems.append(
                    CodeProblem(
                        line: line(variable), span: variable.trimmedDescription,
                        "@\(subscribed) should hold the object that sends the events, a Schedule or a Timer, while `\(held)` is none"))
                continue
            }
            let events = Dictionary(followed.events.map { (DynamicObject.handler(for: $0.key), $0.value) }) {
                first, _ in first
            }
            let owner = followed.name
            guard !events.isEmpty else {
                problems.append(
                    CodeProblem(
                        line: line(variable), span: variable.trimmedDescription,
                        "@\(subscribed) should hold an object that announces events, while `\(type)` announces none"))
                continue
            }
            let object = script.uses.ids(of: type).first?.rawValue ?? type
            let handling = methods.filter { events[$0.name.text] != nil }
            guard !handling.isEmpty else {
                let listed = events.sorted { $0.key < $1.key }.map { handler(of: $0.value.name, in: owner) }.joined(
                    separator: ", ")
                problems.append(
                    CodeProblem(
                        line: line(variable), span: variable.trimmedDescription,
                        "no function handles the events of \(object): \(listed)"))
                continue
            }
            // Each takes its event's value, and nothing else.
            for method in handling {
                guard let event = events[method.name.text] else { continue }
                let parameters = method.signature.parameterClause.parameters
                guard parameters.count == 1, let value = parameters.first, value.firstName.text == "_",
                    value.type.trimmedDescription == "\(owner).\(event.name)"
                else {
                    problems.append(
                        CodeProblem(
                            line: line(method.name),
                            span: "func \(method.name.text)\(method.signature.parameterClause.trimmedDescription)",
                            "the event of \(object) calls \(handler(of: event.name, in: owner))"))
                    continue
                }
            }
        }
        return problems
    }

    /// What a `@Subscribed` property is due as, `schedule` or `timer`, when it holds a `Schedule` or
    /// a `Timer`, as its type is written or its value is made: `Schedule.daily(…)`.
    private static func due(written: String?, value: ExprSyntax?) -> String? {
        let made =
            (value?.as(FunctionCallExprSyntax.self)?.calledExpression ?? value)?.as(MemberAccessExprSyntax.self)?.base?
            .trimmedDescription
        switch written ?? made {
        case "\(Schedule.self)": return "schedule"
        case "\(Timer.self)": return "timer"
        default: return nil
        }
    }

    /// Each `@Event` that isn't a struct or an enum in the actor `actor`, where an event is
    /// declared and announced.
    private static func misplacedEvents(
        in file: SourceFileSyntax, actor: ActorDeclSyntax, line: (AttributeSyntax) -> Int
    ) -> [CodeProblem] {
        final class Marks: SyntaxVisitor {
            var found: [AttributeSyntax] = []
            override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
                if node.attributeName.trimmedDescription == RuntimeMacros.event { found.append(node) }
                return .skipChildren
            }
        }
        let marks = Marks(viewMode: .sourceAccurate)
        marks.walk(file)
        let declared = Set(ObjectModule.events(in: actor))
        return marks.found.compactMap { attribute in
            let declaration = attribute.parent?.parent
            let name =
                declaration?.as(StructDeclSyntax.self)?.name.text ?? declaration?.as(EnumDeclSyntax.self)?.name.text
            if let name, declared.contains(name),
                declaration?.parent?.parent?.parent?.parent?.as(ActorDeclSyntax.self)?.name.text == actor.name.text
            {
                return nil
            }
            let written = declaration.map { $0.trimmedDescription.split(separator: "\n").first.map(String.init) ?? "" }
            return CodeProblem(
                line: line(attribute), span: written,
                "@\(event) is a struct's or an enum's, declared in `actor \(actor.name.text)`: `announce(_:)` sends a value of it")
        }
    }
}
