import DiscoverableActors
import TurgaiObjects
import Yams

/// What an object shows of itself, for a person to read: written in Markdown, which can hold its
/// data and code in blocks of their own.
public enum Card: Codable, Sendable, Equatable {
    case markdown(String)
}

extension ObjectSession {
    /// The card a person reads for `handle`. While it works, it's what the object is, as YAML:
    /// its data now and what it takes, publishes and announces; then, for an object made here, its
    /// Swift. While it's failing, it's why, with its Swift, which is where the failure is.
    /// The card of the object listed by `handle`, among those whoever asks may read: none when it
    /// isn't one of them.
    public func card(named handle: String) async throws -> Card? {
        let listed = builtIns + (try await spaceObjects.held())
        guard let entry = listed.first(where: { $0.id.description == handle }) else { return nil }
        return try await card(entry.id)
    }

    public func card(_ handle: ObjectID) async throws -> Card {
        let description = try await described(handle)
        var parts = ["# \(description.type)"]
        if let summary = description.description, !summary.isEmpty { parts.append(summary) }
        let made = try await madeObject(handle)
        if let made, case .failing(let failure) = try await made.health {
            parts.append("**Last failed:** \(failure.written)")
            parts.append("```swift\n\(try await made.source.code)\n```")
            return .markdown(parts.joined(separator: "\n\n"))
        }
        let current = try await values(handle)
        if current != "{}" { parts.append("```yaml\n\(current)\n```") }
        // Its spec: what it takes, publishes and announces, as Swift declares each.
        if let yaml = try Self.spec(of: Uses.Object(description: description, publishes: true)) {
            parts.append("```yaml\n\(yaml)\n```")
        }
        // An object made here: its Swift, where how it does each is.
        if let made { parts.append("```swift\n\(try await made.source.code)\n```") }
        return .markdown(parts.joined(separator: "\n\n"))
    }
}

extension ObjectSession {
    /// `object`'s spec as YAML: what it takes, what it publishes and what it announces, each as
    /// Swift declares it. `nil` for an object with none of them.
    static func spec(of object: Uses.Object) throws -> String? {
        guard let actor = Uses.interface(of: [object]).actors(events: [RuntimeMacros.event]).first else { return nil }
        var root: [(Node, Node)] = []
        let takes = actor.methods.sorted { $0.key < $1.key }.map { Node(written($0.key, $0.value)) }
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

extension Failure {
    /// What failed and why, in a line: `askForRaise(amount: 200)`: line 22: …
    var written: String {
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
