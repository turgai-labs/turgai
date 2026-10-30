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
        var problems = Self.misplaced(in: file, actor: actor, line: line)
        for member in actor.memberBlock.members {
            // A stored property's: one worked out from others is misplaced, said above.
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                let attribute = subscribedAttribute(in: variable.attributes),
                variable.bindings.allSatisfy({ $0.accessorBlock == nil }),
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
                        "@\(subscribed) takes no arguments: it follows the object its property holds"))
                continue
            }
            // What it follows, and the function each of its events calls: a Schedule or a Timer
            // announces it's due, to the function its property names; an object announces its
            // events, each to the function named like it.
            let object: String
            let handlers: [Handler]
            if Self.isDue(written: written, value: binding.initializer?.value) {
                object = property
                let name = Schedule.handler(for: property)
                handlers = [
                    Handler(name: name, written: "\(name)(at: Date)") { parameters in
                        parameters.count == 1 && parameters.first?.firstName.text == "at"
                            && parameters.first?.type.trimmedDescription == "Date"
                    }
                ]
            } else {
                // An object that exists, which it holds: as written, or as made.
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
                            "@\(subscribed) should hold the object that sends the events, while `\(held)` is no object"))
                    continue
                }
                guard !followed.events.isEmpty else {
                    problems.append(
                        CodeProblem(
                            line: line(variable), span: variable.trimmedDescription,
                            "@\(subscribed) should hold an object that announces events, while `\(type)` announces none"))
                    continue
                }
                object = script.uses.ids(of: type).first?.rawValue ?? type
                let owner = followed.name
                // Each takes its event's value, and nothing else.
                handlers = followed.events.keys.sorted().map { event in
                    Handler(name: DynamicObject.handler(for: event), written: handler(of: event, in: owner)) {
                        parameters in
                        parameters.count == 1 && parameters.first?.firstName.text == "_"
                            && parameters.first?.type.trimmedDescription == "\(owner).\(event)"
                    }
                }
            }
            let handling = methods.filter { method in handlers.contains { $0.name == method.name.text } }
            guard !handling.isEmpty else {
                problems.append(
                    CodeProblem(
                        line: line(variable), span: variable.trimmedDescription,
                        "no function handles the events of \(object): \(handlers.map(\.written).joined(separator: ", "))"
                    ))
                continue
            }
            for method in handling {
                guard let handler = handlers.first(where: { $0.name == method.name.text }),
                    !handler.takes(method.signature.parameterClause.parameters)
                else { continue }
                problems.append(
                    CodeProblem(
                        line: line(method.name),
                        span: "func \(method.name.text)\(method.signature.parameterClause.trimmedDescription)",
                        "the event of \(object) calls \(handler.written)"))
            }
        }
        return problems
    }

    /// A function an event calls: its name, as Swift declares it, and whether what it's declared to
    /// take is what the event gives.
    private struct Handler {
        let name: String
        let written: String
        let takes: (FunctionParameterListSyntax) -> Bool
    }

    /// Whether a `@Subscribed` property holds a `Schedule` or a `Timer`, as its type is written or its
    /// value is made: `Schedule.daily(…)`.
    private static func isDue(written: String?, value: ExprSyntax?) -> Bool {
        let made =
            (value?.as(FunctionCallExprSyntax.self)?.calledExpression ?? value)?.as(MemberAccessExprSyntax.self)?.base?
            .trimmedDescription
        return ["\(Schedule.self)", "\(Timer.self)"].contains(written ?? made ?? "")
    }

    /// Each of the runtime's attributes where Swift lets it attach but the runtime has nothing for
    /// it: an `@Event` type not declared in the actor `actor`, where an event is declared and
    /// announced, and a `@Subscribed` property that isn't one of its stored properties, whose
    /// value it follows. Anywhere else, Swift refuses it, as the macros the runtime declares.
    private static func misplaced(
        in file: SourceFileSyntax, actor: ActorDeclSyntax, line: (AttributeSyntax) -> Int
    ) -> [CodeProblem] {
        final class Marks: SyntaxVisitor {
            var found: [AttributeSyntax] = []
            override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
                if [RuntimeMacros.event, RuntimeMacros.subscribed].contains(node.attributeName.trimmedDescription) {
                    found.append(node)
                }
                return .skipChildren
            }
        }
        let marks = Marks(viewMode: .sourceAccurate)
        marks.walk(file)
        return marks.found.compactMap { attribute in
            guard let declaration = attribute.parent?.parent?.as(DeclSyntax.self) else { return nil }
            // Declared in the actor itself, as one of its members.
            let inActor =
                declaration.parent?.parent?.parent?.parent?.as(ActorDeclSyntax.self)?.name.text == actor.name.text
            let written = declaration.trimmedDescription.split(separator: "\n").first.map(String.init) ?? ""
            if attribute.attributeName.trimmedDescription == subscribed {
                guard let variable = declaration.as(VariableDeclSyntax.self) else { return nil }
                if inActor, variable.bindings.allSatisfy({ $0.accessorBlock == nil }) { return nil }
                return CodeProblem(
                    line: line(attribute), span: written,
                    "@\(subscribed) is a stored property's, in `actor \(actor.name.text)`: it follows what the property holds")
            }
            let isType =
                declaration.is(StructDeclSyntax.self) || declaration.is(EnumDeclSyntax.self)
                || declaration.is(ClassDeclSyntax.self) || declaration.is(ActorDeclSyntax.self)
                || declaration.is(ProtocolDeclSyntax.self)
            guard isType else { return nil }
            if inActor, declaration.is(StructDeclSyntax.self) || declaration.is(EnumDeclSyntax.self) { return nil }
            return CodeProblem(
                line: line(attribute), span: written,
                "@\(event) is a struct's or an enum's, declared in `actor \(actor.name.text)`: `announce(_:)` sends a value of it")
        }
    }
}
