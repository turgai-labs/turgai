import Parsing

/// The small grammars written inside a behavior: a signature, a guard, what an action does, and a
/// send. Each reads text into plain syntax; what a name means is decided by whoever reads the
/// behavior, which knows its fields and parameters.
enum Grammar {
    /// A value as written: quoted text, a number, an empty list, or a word, such as a field's name.
    enum Value: Equatable, Sendable {
        case text(String)
        case integer(Int64)
        case number(Double)
        case emptyList
        case word(String)
    }

    struct Parameter: Equatable, Sendable {
        let name: String
        let type: String
    }

    struct Argument: Equatable, Sendable {
        let name: String
        let value: Value
    }

    struct SignatureSyntax: Equatable, Sendable {
        let name: String
        let parameters: [Parameter]
        let reply: String?
    }

    struct SendSyntax: Equatable, Sendable {
        let receiver: String
        let message: String
        /// Each argument by name; `name` alone stands for `name: name`.
        let arguments: [Argument]
    }

    enum GuardSyntax: Equatable, Sendable {
        case compare(Value, Behavior.Comparison, Value)
        case check(Value, Behavior.Comparison)
    }

    /// Reads all of `text` with `parser`, or shows where it stopped: the text, and a caret under
    /// the spot, the way Elm points at a mistake. What was expected there is for the caller to
    /// say, in words.
    static func read<P: Parser<Substring, Output>, Output>(_ text: String, with parser: P) throws(BehaviorError) -> Output {
        let text = text.trimmingCharacters(in: .whitespaces)
        do {
            return try parser.parse(text)
        } catch {
            // swift-parsing reports the spot as ` --> input:line:column`.
            let column = String(describing: error)
                .firstMatch(of: /--> input:\d+:(\d+)/)
                .flatMap { Int($0.1) } ?? 1
            throw BehaviorError("    \(text)\n    " + String(repeating: " ", count: max(column - 1, 0)) + "^")
        }
    }
}

// MARK: - Pieces

/// Spaces, as many as there are.
struct Spaces: Parser {
    var body: some Parser<Substring, Void> {
        Prefix { (character: Character) in character == " " }.map { _ in () }
    }
}

/// At least one space, between words.
struct Gap: Parser {
    var body: some Parser<Substring, Void> {
        Prefix(1...) { (character: Character) in character == " " }.map { _ in () }
    }
}

/// A name: a letter, then letters, digits or `_`.
struct Identifier: Parser {
    var body: some Parser<Substring, String> {
        Parse(input: Substring.self) {
            Prefix(1, while: { (character: Character) in character.isLetter || character == "_" })
            Prefix { (character: Character) in character.isLetter || character.isNumber || character == "_" }
        }.map { (first: Substring, rest: Substring) in String(first) + String(rest) }
    }
}

/// A handle, such as `refund-manager-ann`, or a name.
struct Handle: Parser {
    var body: some Parser<Substring, String> {
        Prefix(1...) { (character: Character) in
            character.isLetter || character.isNumber || character == "_" || character == "-"
        }.map { (handle: Substring) in String(handle) }
    }
}

/// A type: a word, or a protocol's name of several words, up to `,`, `)` or `->`.
struct TypeName: Parser {
    var body: some Parser<Substring, String> {
        Prefix(1...) { (character: Character) in character != "," && character != ")" && character != "-" }
            .map { (name: Substring) in name.trimmingCharacters(in: .whitespaces) }
    }
}

struct ValueParser: Parser {
    var body: some Parser<Substring, Grammar.Value> {
        OneOf {
            Parse(input: Substring.self) {
                "'"
                PrefixUpTo("'")
                "'"
            }.map { (text: Substring) in Grammar.Value.text(String(text)) }
            Parse(input: Substring.self) {
                "\""
                PrefixUpTo("\"")
                "\""
            }.map { (text: Substring) in Grammar.Value.text(String(text)) }
            "[]".map { Grammar.Value.emptyList }
            Prefix(1...) { (character: Character) in character.isNumber || character == "." || character == "-" }
                .compactMap { (digits: Substring) -> Grammar.Value? in
                    if let integer = Int64(digits) { return .integer(integer) }
                    if let number = Double(digits), number.isFinite { return .number(number) }
                    return nil
                }
            Identifier().map { Grammar.Value.word($0) }
        }
    }
}

// MARK: - Forms

/// `raiseRequested(amount: number, worker: salary answers) -> number`, `reset()`, `reset`.
struct SignatureParser: Parser {
    var body: some Parser<Substring, Grammar.SignatureSyntax> {
        Parse(input: Substring.self) {
            Identifier()
            Optionally {
                Spaces()
                "("
                Spaces()
                Many {
                    Identifier()
                    Spaces()
                    ":"
                    Spaces()
                    TypeName()
                } separator: {
                    Spaces()
                    ","
                    Spaces()
                }
                Spaces()
                ")"
            }
            Optionally {
                Spaces()
                "->"
                Spaces()
                Rest().map { (type: Substring) in type.trimmingCharacters(in: .whitespaces) }
            }
        }.map { (name: String, parameters: [(String, String)]?, reply: String?) in
            Grammar.SignatureSyntax(
                name: name, parameters: (parameters ?? []).map { Grammar.Parameter(name: $0.0, type: $0.1) }, reply: reply)
        }
    }
}

/// `amount <= remaining`, `reviewing contains number`, `reviewing is not empty`.
struct GuardParser: Parser {
    var body: some Parser<Substring, Grammar.GuardSyntax> {
        OneOf {
            Parse(input: Substring.self) {
                ValueParser()
                Gap()
                "is not empty"
            }.map { (value: Grammar.Value) in Grammar.GuardSyntax.check(value, .isNotEmpty) }
            Parse(input: Substring.self) {
                ValueParser()
                Gap()
                "is empty"
            }.map { (value: Grammar.Value) in Grammar.GuardSyntax.check(value, .isEmpty) }
            Parse(input: Substring.self) {
                ValueParser()
                Gap()
                "contains"
                Gap()
                ValueParser()
            }.map { (list: Grammar.Value, item: Grammar.Value) in Grammar.GuardSyntax.compare(list, .contains, item) }
            Parse(input: Substring.self) {
                ValueParser()
                Spaces()
                OneOf {
                    "<=".map { Behavior.Comparison.atMost }
                    ">=".map { Behavior.Comparison.atLeast }
                    "==".map { Behavior.Comparison.equal }
                    "!=".map { Behavior.Comparison.notEqual }
                    "<".map { Behavior.Comparison.lessThan }
                    ">".map { Behavior.Comparison.greaterThan }
                }
                Spaces()
                ValueParser()
            }.map { (left: Grammar.Value, comparison: Behavior.Comparison, right: Grammar.Value) in
                Grammar.GuardSyntax.compare(left, comparison, right)
            }
        }
    }
}

/// `amount to salary`, `amount from remaining`: a value, a word, and a field.
struct ValueThenField: Parser {
    let word: String

    var body: some Parser<Substring, (Grammar.Value, String)> {
        Parse(input: Substring.self) {
            ValueParser()
            Gap()
            word
            Gap()
            Identifier()
        }
    }
}

/// `lastAnswer to 'approved'`: a field, `to`, and a value.
struct FieldToValue: Parser {
    var body: some Parser<Substring, (String, Grammar.Value)> {
        Parse(input: Substring.self) {
            Identifier()
            Gap()
            "to"
            Gap()
            ValueParser()
        }
    }
}

/// `manager.raiseRequested(amount, worker: self)`.
struct SendParser: Parser {
    var body: some Parser<Substring, Grammar.SendSyntax> {
        Parse(input: Substring.self) {
            Handle()
            "."
            Identifier()
            Spaces()
            "("
            Spaces()
            Many {
                OneOf {
                    Parse(input: Substring.self) {
                        Identifier()
                        Spaces()
                        ":"
                        Spaces()
                        ValueParser()
                    }.map { (name: String, value: Grammar.Value) in Grammar.Argument(name: name, value: value) }
                    Identifier().map { Grammar.Argument(name: $0, value: .word($0)) }
                }
            } separator: {
                Spaces()
                ","
                Spaces()
            }
            Spaces()
            ")"
        }.map { (receiver: String, message: String, arguments: [Grammar.Argument]) in
            Grammar.SendSyntax(receiver: receiver, message: message, arguments: arguments)
        }
    }
}
