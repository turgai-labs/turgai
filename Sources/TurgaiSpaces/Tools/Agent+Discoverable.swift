import AttributedCalls
import DiscoverableActors
import DistributedCluster
import Foundation
import Hail
import TurgaiCalls
import TurgaiDomain
import TurgaiHail
import TurgaiObjects
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#endif

// A profile's agent, as an object: it describes itself as `@Discoverable` would describe its own
// `respond(_:)` answering in text, `func respond(_ request: String) async throws -> String`, its
// schemas from those types. The agents
// Turgai lists are the ones asked as objects: one per profile, shared as made objects are, with a
// history of its own.
extension Agent: @retroactive DiscoverableActor {
    private static let objectType = "Agent"

    public distributed func describe() -> ObjectDescription {
        Self.describe()
    }

    /// What every agent is and takes, the same on every node running this code: whoever knows an
    /// object is an agent reads it here, and doesn't start the agent to ask.
    static func describe() -> ObjectDescription {
        let respond = "Ask the agent, and wait for its answer."
        return ObjectDescription(
            type: Agent.objectType,
            description: "An agent: ask it something, and it answers.",
            properties: [:],
            actions: [
                "respond": ObjectAction(
                    description: respond,
                    input: _DiscoverySupport.schema(
                        description: respond,
                        parameters: [
                            Discovery.parameter(
                                "request", description: "What you ask, in words.",
                                type: _DiscoverySupport.described(String.self))
                        ]),
                    output: Discovery.schema(for: _DiscoverySupport.described(String.self)),
                    safe: false,
                    idempotent: false,
                    effects: [.async, .throws])
            ],
            events: [:])
    }

    @discardableResult
    public distributed func invoke(
        _ action: String, arguments: DiscoverableActors.JSONValue, through type: String?
    ) async throws -> DiscoverableActors.JSONValue {
        // Sent through a protocol, `any …`, it's for any actor taking the action.
        if let type, !type.hasPrefix("any "), type != Self.objectType {
            throw DiscoveryError.notA(type, isA: Self.objectType)
        }
        switch action {
        case "respond":
            try _DiscoverySupport.validate(arguments, allowedKeys: ["request"])
            let request = try _DiscoverySupport.argument(
                String.self, "request", in: arguments, actorSystem: actorSystem)
            // A call that came from its own answer: it can't answer it until it has answered. The
            // call says the actors it came through; the last is this one, reached now.
            if Call.path.dropLast().contains(agentID.actorID) {
                throw AgentAskError.askedByItself(agentID.role)
            }
            do {
                let answer: String = try await respond(request)
                return try _DiscoverySupport.json(answer)
            } catch AgentRuntimeError.busy(let busy) {
                throw AgentAskError.busy(agentID.role, busy)
            }
        default:
            throw DiscoveryError.unknownAction(action)
        }
    }

    public distributed func read(property name: String) throws -> DiscoverableActors.JSONValue {
        throw DiscoveryError.unknownProperty(name)
    }

    public distributed func _subscribe(_ subscriber: _SubscriberID, to event: String) async throws {
        throw DiscoveryError.unknownEvent(event)
    }

    public distributed func _nextEvent(for subscriber: _SubscriberID) async throws -> _EventDelivery {
        .ended
    }

    public distributed func _unsubscribe(_ subscriber: _SubscriberID) async throws {}
}

/// Every agent is read by everyone and written by no one, until agents have makers: every call to
/// one is on someone's behalf.
extension Agent: AccessControlled {
    public distributed func access(for chain: CallChain) -> Access { .readByEveryone }
}

/// Why an agent asked as an object didn't answer.
public enum AgentAskError: Error, Sendable, Equatable, Codable, CustomStringConvertible {
    /// It was busy, with what it was doing: it does one thing at a time.
    case busy(Role, AgentStatus.Busy)
    /// The call came from its own answer: the agent asked is the one asking.
    case askedByItself(Role)

    public var description: String {
        switch self {
        case .busy(let role, .responding): "The \(role.rawValue) agent is busy answering."
        case .busy(let role, .compacting): "The \(role.rawValue) agent is busy compacting its history."
        case .askedByItself(let role): "The \(role.rawValue) agent is you: this call came from your own answer."
        }
    }
}

extension Agent {
    /// The agent of `role` asked as an object in `space`.
    static func asked(_ role: Role, in space: SpaceID) -> AgentID {
        AgentID(role: role, contextID: AgentContext.asked(as: role, in: space).contextID)
    }

    /// The id the agent with `id` is known by, as an object and in call chains: its virtual actor's.
    public static func objectID(of id: AgentID) -> ObjectID {
        .virtual(id.actorID)
    }

    /// The agents of `roles`, bots of `space`, asked as objects there, as their objects are listed:
    /// each checked in where made objects are, where code finds it by its name, and described as
    /// every agent is. None starts until it's asked.
    public static func offered(_ roles: [Role], in space: SpaceID, on system: ClusterSystem) async throws
        -> [ObjectEntry]
    {
        var entries: [ObjectEntry] = []
        let description = describe()
        for role in roles {
            let agentID = asked(role, in: space)
            let agent = try await Agent.identified(by: agentID, on: system)
            let object = try DiscoverableObject.resolve(id: agent.id, using: system)
            await system.receptionist.checkIn(object, with: .virtualObjects(in: space))
            entries.append(
                ObjectEntry(
                    id: objectID(of: agentID), object: object, type: objectType,
                    description: description.description,
                    actions: description.actions.map { ObjectCatalog.signature($0.key, input: $0.value.input) }
                        .sorted()))
        }
        return entries
    }
}
