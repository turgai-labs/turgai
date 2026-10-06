import DiscoverableActors

/// A named set of messages: what an object accepts. Objects speak protocols, and references
/// are typed by them: a reference typed `salary answers` holds any object that accepts at least
/// its messages, the way set-theoretic types read a type as a set of values.
public struct MessageProtocol: Codable, Sendable, Equatable {
    public let name: String
    public let messages: [Signature]

    public init(name: String, messages: [Signature]) {
        self.name = name
        self.messages = messages
    }

    public var written: String { messages.map(\.written).joined(separator: "\n") }
}

extension MessageProtocol {
    /// Protocols written together, which can name each other, and any protocol in `known`.
    public static func read(_ written: [Written], known: [String: MessageProtocol]) throws(BehaviorError) -> [MessageProtocol] {
        // Every name first, so protocols written together can name each other.
        var protocols = known
        for item in written { protocols[item.name] = MessageProtocol(name: item.name, messages: []) }
        var read: [MessageProtocol] = []
        for item in written {
            guard !item.messages.isEmpty else {
                throw BehaviorError("`\(item.name)` has no messages: a protocol is the messages objects that speak it take.")
            }
            var messages: [Signature] = []
            for (index, message) in item.messages.enumerated() {
                let path = "`\(item.name)`.messages[\(index)]"
                try Signature.checkName(message.name, what: "message")
                guard !messages.contains(where: { $0.name == message.name }) else {
                    throw BehaviorError("`\(item.name)` has `\(message.name)` twice. Each message is written once.")
                }
                var parameters: [Parameter] = []
                for (number, parameter) in (message.parameters ?? []).enumerated() {
                    guard !parameters.contains(where: { $0.name == parameter.name }) else {
                        throw BehaviorError("\(path): `\(message.name)` has the parameter `\(parameter.name)` twice.")
                    }
                    parameters.append(
                        Parameter(
                            name: parameter.name,
                            type: try ValueType(parameter, at: "\(path).parameters[\(number)]", protocols: protocols)))
                }
                messages.append(Signature(name: message.name, parameters: parameters, reply: message.reply?.valueType))
            }
            read.append(MessageProtocol(name: item.name, messages: messages))
        }
        return read
    }
}

extension Signature {
    static func checkName(_ name: String, what: String) throws(BehaviorError) {
        let valid = name.first.map { $0.isLetter || $0 == "_" } == true
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        guard valid else {
            let words = name.split { !$0.isLetter && !$0.isNumber }
            let suggestion = words.enumerated().map { index, word in
                index == 0 ? word.lowercased() : word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }.joined()
            let instead = suggestion.isEmpty || suggestion == name ? "such as `refundRequested`" : "such as `\(suggestion)`"
            throw BehaviorError("`\(name)` isn't a valid \(what) name: use letters and digits, with no spaces, \(instead).")
        }
    }
}


// MARK: - Inclusion

/// Whether one type is in another, read as sets of values, the way Elixir's set-theoretic types
/// check: `integer` is in `number`; an object that speaks a protocol accepting more messages is
/// in one that accepts fewer.
struct Types {
    let protocols: [String: MessageProtocol]

    /// Whether every value of `a` is a value of `b`. `object` is unchecked both ways: anything is
    /// an object, and an object given where a protocol is asked is checked when a message
    /// arrives, as Erlang would.
    func isSubtype(_ a: ValueType, of b: ValueType) -> Bool {
        var assumed: Set<Pair> = []
        return isSubtype(a, of: b, assuming: &assumed)
    }

    /// Whether `a` accepts at least what `b` asks for: each message of `b`, with the same
    /// parameters, each taking at least what `b` sends, and a reply that's at least as precise.
    func accepts(_ a: MessageProtocol, everythingIn b: MessageProtocol) -> Bool {
        var assumed: Set<Pair> = []
        return accepts(a, everythingIn: b, assuming: &assumed)
    }

    /// The first message of `b` that `a` doesn't accept as `b` asks, with why, for errors.
    func firstGap(in a: MessageProtocol, for b: MessageProtocol) -> String? {
        for wanted in b.messages {
            guard let taken = a.messages.first(where: { $0.name == wanted.name }) else {
                return "it doesn't take `\(wanted.written)`"
            }
            guard fits(taken, wanted) else {
                return "it takes `\(taken.written)`, not `\(wanted.written)`"
            }
        }
        return nil
    }

    private struct Pair: Hashable {
        let a: String
        let b: String
    }

    private func isSubtype(_ a: ValueType, of b: ValueType, assuming assumed: inout Set<Pair>) -> Bool {
        switch (a, b) {
        case _ where a == b: return true
        case (.integer, .number): return true
        case (.speaks, .object), (.object, .speaks): return true
        case (.speaks(let x), .speaks(let y)):
            guard let left = protocols[x], let right = protocols[y] else { return false }
            return accepts(left, everythingIn: right, assuming: &assumed)
        default: return false
        }
    }

    private func accepts(_ a: MessageProtocol, everythingIn b: MessageProtocol, assuming assumed: inout Set<Pair>) -> Bool {
        let pair = Pair(a: a.name, b: b.name)
        // Protocols that mention each other: assume this pair holds while checking it.
        guard assumed.insert(pair).inserted else { return true }
        return b.messages.allSatisfy { wanted in
            a.messages.contains { taken in taken.name == wanted.name && fits(taken, wanted, assuming: &assumed) }
        }
    }

    private func fits(_ taken: Signature, _ wanted: Signature) -> Bool {
        var assumed: Set<Pair> = []
        return fits(taken, wanted, assuming: &assumed)
    }

    /// A handler `taken` serves senders of `wanted`: same parameter names; whatever is sent for
    /// each is something it takes; and its reply, if one is wanted, is what's expected.
    private func fits(_ taken: Signature, _ wanted: Signature, assuming assumed: inout Set<Pair>) -> Bool {
        guard taken.parameters.map(\.name).sorted() == wanted.parameters.map(\.name).sorted() else { return false }
        for parameter in wanted.parameters {
            guard let own = taken.parameters.first(where: { $0.name == parameter.name }),
                isSubtype(parameter.type, of: own.type, assuming: &assumed)
            else { return false }
        }
        guard let expected = wanted.reply else { return true }
        guard let given = taken.reply else { return false }
        return isSubtype(given, of: expected, assuming: &assumed)
    }
}
