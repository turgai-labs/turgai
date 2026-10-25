/// An agent's or an object's identity, as the actor running it is known everywhere: its virtual
/// actor's id.
public struct ActorIdentity: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Its name, as it's shown: the last part of its id, its id within its scope.
    public var name: String {
        rawValue.split(separator: "/").last.map(String.init) ?? rawValue
    }
}

/// Someone whose code makes a call: a person, an agent, or an object.
public enum Party: Codable, Sendable, Hashable, CustomStringConvertible {
    case person(UserID)
    case agent(ActorIdentity)
    case object(ActorIdentity)

    public var description: String {
        switch self {
        case .person(let user): user.rawValue
        case .agent(let id), .object(let id): id.name
        }
    }
}

/// The parties whose code a call came through, the first first: who it comes from, and what makes
/// calls that go round in a circle fail, with the circle as the reason, instead of running until
/// memory runs out.
public struct CallChain: Codable, Sendable, Equatable {
    public let parties: [Party]

    /// How deep calls may go.
    static let limit = 64

    /// A call from no one's code: the start of a chain.
    public static let start = CallChain(parties: [])

    /// The chain of a call `caller` makes, refused once it's too deep.
    public func continuing(from caller: Party) throws(CallsTooDeep) -> CallChain {
        let next = CallChain(parties: parties + [caller])
        guard next.parties.count <= Self.limit else { throw CallsTooDeep(chain: next) }
        return next
    }

    /// Whether `party`'s code is one the call came through.
    public func contains(_ party: Party) -> Bool {
        parties.contains(party)
    }

    /// The chain the current task's calls continue.
    @TaskLocal public static var current: CallChain?

    /// The chain the current task is in: none set is the start of one.
    public static var ongoing: CallChain { current ?? .start }
}

/// Calls that went deeper than a chain may go.
public struct CallsTooDeep: Error, Sendable, Equatable, CustomStringConvertible {
    public let chain: CallChain

    public var description: String {
        "calls went \(chain.parties.count) deep: "
            + (chain.parties.prefix(6).map(\.description) + (chain.parties.count > 6 ? ["…"] : []))
            .joined(separator: " → ")
    }
}
