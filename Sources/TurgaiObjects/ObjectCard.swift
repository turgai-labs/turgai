import DiscoverableActors
import DistributedCluster
import Yams

/// What an object shows of itself, for a person to read: written in Markdown, which can hold its
/// data and code in blocks of their own.
public enum Card: Codable, Sendable, Equatable {
    case markdown(String)

    /// The card of what `description` describes. While it works, it's what the object is, as YAML:
    /// its `values` now and what it takes, publishes and announces; then, for an object made
    /// here, its Swift, `code`. While it's failing, it's why, `failure`, with its Swift, which is
    /// where the failure is.
    public init(
        _ description: ObjectDescription, values: [String: JSONValue], failure: Failure? = nil, code: String? = nil
    ) throws {
        var parts = ["# \(description.type)"]
        if let summary = description.description, !summary.isEmpty { parts.append(summary) }
        if let failure {
            parts.append("**Last failed:** \(failure.written)")
            if let code { parts.append("```swift\n\(code)\n```") }
            self = .markdown(parts.joined(separator: "\n\n"))
            return
        }
        let current = try JSONValue.object(values).yaml
        if current != "{}" { parts.append("```yaml\n\(current)\n```") }
        // Its spec: what it takes, publishes and announces, as Swift declares each.
        if let yaml = try Self.spec(of: Uses.Object(description: description, publishes: true)) {
            parts.append("```yaml\n\(yaml)\n```")
        }
        // An object made here: its Swift, where how it does each is.
        if let code { parts.append("```swift\n\(code)\n```") }
        self = .markdown(parts.joined(separator: "\n\n"))
    }

    /// `object`'s spec as YAML: what it takes, what it publishes and what it announces, each as
    /// Swift declares it. `nil` for an object with none of them.
    static func spec(of object: Uses.Object) throws -> String? {
        guard let actor = Uses.interface(of: [object]).actors(events: [RuntimeMacros.event]).first else { return nil }
        var root: [(Node, Node)] = []
        let takes = actor.methods.sorted { $0.key < $1.key }.map { Node($0.value.written(as: $0.key)) }
        if !takes.isEmpty { root.append((Node("takes"), Node(takes))) }
        let publishes = actor.properties.sorted { $0.key < $1.key }.map {
            Node("\($0.key): \($0.value) { get async throws }")
        }
        if !publishes.isEmpty { root.append((Node("publishes"), Node(publishes))) }
        let announces = actor.events.sorted { $0.key < $1.key }.map { Node($0.value.written) }
        if !announces.isEmpty { root.append((Node("announces"), Node(announces))) }
        guard !root.isEmpty else { return nil }
        return try Yams.serialize(node: Node.mapping(Node.Mapping(root)), width: -1, allowUnicode: true)
    }
}

extension DeclaredActor.Method {
    /// It as Swift declares it, named `name`: `show(page: Layout)`, `approve(_ amount: Int) -> Bool`.
    public func written(as name: String) -> String {
        let parameters = parameters.map { parameter in
            let called =
                parameter.label == parameter.name ? parameter.name : "\(parameter.label ?? "_") \(parameter.name)"
            return "\(called): \(parameter.type)"
        }
        return "\(name)(\(parameters.joined(separator: ", ")))" + (effects.map { " \($0)" } ?? "")
            + (returns.map { " -> \($0)" } ?? "")
    }
}

extension JSONValue {
    /// The value as YAML, the way a model writes its arguments, keys sorted.
    public var yaml: String {
        get throws { try Yams.dump(object: plain, sortKeys: true).trimmingCharacters(in: .newlines) }
    }

    private var plain: Any {
        switch self {
        // Nothing, which Yams writes as `null`.
        case .null: Optional<Any>.none as Any
        case .bool(let bool): bool
        // A whole number reads as one: YAML would write 3000.0 as 3e+3.
        case .number(let number) where number.rounded() == number && abs(number) < 1e15: Int(number)
        case .number(let number): number
        case .integer(let integer): Int(integer)
        case .unsignedInteger(let integer): Int(clamping: integer)
        case .string(let string): string
        case .array(let elements): elements.map(\.plain)
        case .object(let members): members.mapValues(\.plain)
        }
    }
}

extension Card {
    /// `object`, as an object holding it shows it: its type, and what it holds.
    public static func inside(_ object: DiscoverableObject) async throws -> String {
        let description = try await object.describe()
        var held: [String] = []
        for name in description.properties.keys.sorted() {
            held.append("\(name): \(try await object.read(property: name).inline)")
        }
        return "a `\(description.type)`" + (held.isEmpty ? "" : " holding " + held.joined(separator: ", "))
    }
}

extension Failure {
    /// What failed and why, in a line: `askForRaise(amount: 200)`: line 22: …
    public var written: String {
        switch origin {
        case .message(let delivery): "`\(delivery.written)`: \(problem)"
        case .event(let delivery, let from): "`\(delivery.written)`, an event from \(from): \(problem)"
        case .task: "a task it started: \(problem)"
        }
    }
}

extension Delivery {
    /// The message as it was sent: `askForRaise(amount: 200)`.
    var written: String {
        guard case .object(let arguments) = arguments else { return "\(message)()" }
        return "\(message)("
            + arguments.sorted { $0.key < $1.key }.map { "\($0.key): \(Self.argument($0.value))" }.joined(
                separator: ", ") + ")"
    }

    /// An argument as it reads: an object as one, never its address.
    private static func argument(_ value: JSONValue) -> String {
        ObjectReference(value) == nil ? value.inline : "an object"
    }
}
