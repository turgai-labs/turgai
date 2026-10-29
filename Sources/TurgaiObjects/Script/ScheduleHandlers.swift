import Doppel
import SwiftParser
import SwiftSyntax

/// What an object's schedules and timers call, which Swift doesn't know: each `Schedule` or `Timer`
/// property it holds is handled by its `on<Property>Fired(at: Date)`.
public enum ScheduleHandlers {
    /// The rule, as the code's writer is told it.
    public static let rule =
        "A stored property of type `Schedule` or `Timer` is due as it says: each time, the object's `on<Property>Fired(at: Date)` is called."

    /// Each `Schedule` property of the actor `type` in `code` without its handler, or with one that
    /// takes other than what the schedule gives, at its line, as the checker resolved its type.
    static func problems(in code: String, type: String, declarations: Declarations) -> [CodeProblem] {
        guard case .actor(let fields, _, _, _)? = declarations[type] else { return [] }
        let file = Parser.parse(source: code)
        let lines = SourceLocationConverter(fileName: "", tree: file)
        func line(_ node: some SyntaxProtocol) -> Int {
            lines.location(for: node.positionAfterSkippingLeadingTrivia).line
        }
        guard
            let actor = file.statements.lazy.compactMap({ $0.item.as(ActorDeclSyntax.self) }).first(where: {
                $0.name.text == type
            })
        else { return [] }
        let functions = actor.memberBlock.members.compactMap { $0.decl.as(FunctionDeclSyntax.self) }
        let variables = actor.memberBlock.members.compactMap { $0.decl.as(VariableDeclSyntax.self) }
        var problems: [CodeProblem] = []
        for field in fields {
            guard let kind = Self.kind(of: field.type) else { continue }
            let handler = Schedule.handler(for: field.name)
            let wanted = "\(handler)(at: Date)"
            let declared = variables.first { $0.bindings.contains { $0.pattern.trimmedDescription == field.name } }
            guard let function = functions.first(where: { $0.name.text == handler }) else {
                problems.append(
                    CodeProblem(
                        line: declared.map(line), span: declared?.trimmedDescription,
                        "no function handles the \(kind) `\(field.name)`: \(wanted)"))
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
                        "the \(kind) `\(field.name)` calls \(wanted)"))
                continue
            }
        }
        return problems
    }

    /// What `type` is due as, `schedule` or `timer`, when it's one's or an optional one's.
    private static func kind(of type: SwiftType) -> String? {
        switch type {
        case .named("\(Schedule.self)", _), .optional(.named("\(Schedule.self)", _)): "schedule"
        case .named("\(Timer.self)", _), .optional(.named("\(Timer.self)", _)): "timer"
        default: nil
        }
    }
}
