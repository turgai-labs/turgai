import SwiftParser
import SwiftSyntax

/// An object's code as the Swift module it is: the module it imports, its runtime, and its own
/// file, all plain Swift. What's Turgai's is said in Swift here: the spec's objects as actors, the
/// objects reached by name as constants, and the runtime's macros as they expand, on the lines
/// they're written, so a line of the module's object file is the line of the code.
///
/// Turgai's Swift goes beyond Swift in one way: another object of a type the code doesn't declare
/// is an `Object`, and a method called on one is a message.
public struct ObjectModule: Sendable {
    /// A file of the module: its name, and its code.
    public struct File: Sendable, Hashable {
        public let name: String
        public let code: String
    }

    /// The file with the object's own code.
    public static let objectFile = "Object.swift"

    /// The label of the id every object is made with, `Type(id:)`, as a distributed actor is with
    /// its actor system: its own type's included, which has no other initializer.
    public static let idLabel = "id"

    public let files: [File]

    public init(_ script: Script) {
        files =
            Self.given(script.uses.interface, lasting: script.uses.lasting) + [
                File(name: Self.objectFile, code: Self.expanded(script.code, type: script.type))
            ]
    }

    /// The file the objects of `interface` are declared in, as code meets them.
    static let objectsFile = "Objects.swift"

    /// The files code is given with `interface`: its objects, with bodies Swift takes, those of the
    /// types in `lasting` named by their ids, and the runtime's own declarations.
    static func given(_ interface: ModuleInterface, lasting: Set<String>) -> [File] {
        let runtime = [
            "/// Another object, of a type this code doesn't declare: what's called on it is a message.",
            "typealias \(Uses.anyObject) = any Actor",
            "",
            "/// What an `@\(RuntimeMacros.event)` function's body calls: the event, announced with its values.",
            "func \(RuntimeMacros.announce)(_ event: String, _ values: [String: any Sendable]) {}",
        ]
        return [
            // Foundation's value types are the module's, as the objects' declarations use them.
            File(name: objectsFile, code: "import Foundation\n\n" + stubbed(interface.source, lasting: lasting)),
            File(name: "Runtime.swift", code: runtime.joined(separator: "\n") + "\n"),
        ]
    }

    /// The files the code is given: all but its own.
    public var given: [File] { files.filter { $0.name != Self.objectFile } }

    /// The spec's declarations with bodies Swift takes: each function and property without one is
    /// given one, which never runs, and its events are plain functions.
    static func stubbed(_ source: String, lasting: Set<String>) -> String {
        Stubbing(lasting: lasting).rewrite(Parser.parse(source: source)).description
    }

    private final class Stubbing: SyntaxRewriter {
        /// The types whose objects last.
        let lasting: Set<String>

        init(lasting: Set<String>) {
            self.lasting = lasting
            super.init(viewMode: .sourceAccurate)
        }

        /// Another object's type is named by its id, `Type(id:)`, when its objects last: the only
        /// way code reaches one by name. One whose objects don't, code only gets from a call.
        override func visit(_ node: ActorDeclSyntax) -> DeclSyntax {
            guard var actor = super.visit(node).as(ActorDeclSyntax.self) else { return super.visit(node) }
            guard lasting.contains(actor.name.text),
                !actor.memberBlock.members.contains(where: { $0.decl.is(InitializerDeclSyntax.self) })
            else {
                return DeclSyntax(actor)
            }
            let named = MemberBlockItemSyntax(
                decl: DeclSyntax("\n    init(\(raw: ObjectModule.idLabel): String) { fatalError() }"))
            actor.memberBlock.members = MemberBlockItemListSyntax([named] + Array(actor.memberBlock.members))
            return DeclSyntax(actor)
        }

        /// A protocol's requirements are declared, never given bodies.
        override func visit(_ node: ProtocolDeclSyntax) -> DeclSyntax {
            DeclSyntax(node)
        }

        override func visit(_ node: FunctionDeclSyntax) -> DeclSyntax {
            var function = node
            function.attributes = AttributeListSyntax(node.attributes.filter { !ObjectModule.isRuntimeMacro($0) })
            // Its line and indent, which an attribute taken away took with it.
            function.leadingTrivia = node.leadingTrivia
            if function.body == nil {
                function.body = CodeBlockSyntax(
                    leftBrace: .leftBraceToken(leadingTrivia: .space), statements: ["fatalError()"],
                    rightBrace: .rightBraceToken())
            }
            return DeclSyntax(function)
        }

        override func visit(_ node: AccessorDeclSyntax) -> DeclSyntax {
            guard node.body == nil else { return DeclSyntax(node) }
            var accessor = node
            accessor.body = CodeBlockSyntax(
                leftBrace: .leftBraceToken(leadingTrivia: .space), statements: ["fatalError()"],
                rightBrace: .rightBraceToken(leadingTrivia: .space))
            return DeclSyntax(accessor)
        }
    }

    static func isRuntimeMacro(_ element: AttributeListSyntax.Element) -> Bool {
        guard let attribute = element.as(AttributeSyntax.self) else { return false }
        let name = attribute.attributeName.trimmedDescription
        return name == RuntimeMacros.event || name == RuntimeMacros.subscribed
    }

    /// The code with the runtime's macros expanded where they're written, keeping its lines: an
    /// `@Event` function announces, and a `@Subscribed` property stays as it's written.
    static func expanded(_ code: String, type: String? = nil) -> String {
        let file = Parser.parse(source: code)
        var edits: [(range: Range<Int>, text: String)] = []
        // Its own actor is made with its id, as every object is, as a distributed actor is with its
        // actor system: `init(id:)`, there when it writes none, which leaves it no `init()`.
        if let actor = file.statements.lazy.compactMap({ $0.item.as(ActorDeclSyntax.self) }).first(where: {
            $0.name.text == type
        }),
            !actor.memberBlock.members.contains(where: { $0.decl.is(InitializerDeclSyntax.self) })
        {
            let end = actor.memberBlock.leftBrace.endPositionBeforeTrailingTrivia.utf8Offset
            edits.append((end..<end, " init(\(idLabel): String) {}"))
        }
        for token in file.tokens(viewMode: .sourceAccurate) {
            guard token.tokenKind == .atSign, let attribute = token.parent?.as(AttributeSyntax.self),
                isRuntimeMacro(.attribute(attribute))
            else { continue }
            edits.append(
                (
                    attribute.positionAfterSkippingLeadingTrivia
                        .utf8Offset..<attribute.endPositionBeforeTrailingTrivia.utf8Offset, ""
                ))
            let declaration = attribute.parent?.parent
            if let function = declaration?.as(FunctionDeclSyntax.self), function.body == nil {
                let values = function.signature.parameterClause.parameters.map { parameter in
                    let name = (parameter.secondName ?? parameter.firstName).text
                    return "\"\(name)\": \(name)"
                }
                let end = function.signature.endPositionBeforeTrailingTrivia.utf8Offset
                edits.append(
                    (
                        end..<end,
                        " { \(RuntimeMacros.announce)(\"\(function.name.text)\", [\(values.isEmpty ? ":" : values.joined(separator: ", "))]) }"
                    ))
            }
        }
        var bytes = Array(code.utf8)
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            bytes.replaceSubrange(edit.range, with: Array(edit.text.utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
