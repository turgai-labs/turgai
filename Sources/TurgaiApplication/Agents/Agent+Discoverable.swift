import DiscoverableActors
import DistributedCluster
import Foundation
import Hail
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
        Self.objectDescription
    }

    /// What every agent is and takes, the same on every node running this code: whoever knows an
    /// object is an agent reads it here, and doesn't start the agent to ask.
    static let objectDescription: ObjectDescription = {
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
    }()

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
            let request = try _DiscoverySupport.argument(String.self, "request", in: arguments, actorSystem: actorSystem)
            let answer: String = try await respond(request)
            return try _DiscoverySupport.json(answer)
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

extension Agent {
    /// The agent of `role` asked as an object.
    static func asked(_ role: Role) -> AgentID {
        AgentID(role: role, contextID: AgentContext.asked(as: role).contextID)
    }

    /// The id an asked agent is listed by: its virtual actor's.
    static func objectID(_ role: Role) -> ObjectID {
        .virtual(VirtualActorID(rawValue: asked(role).rawValue))
    }

    /// The agents of `roles`, asked as objects, as their objects are listed: each checked in where
    /// made objects are, where code finds it by its name, and described as every agent is. None
    /// starts until it's asked.
    public static func offered(_ roles: [Role], on system: ClusterSystem) async throws -> [ObjectEntry] {
        let scope = ObjectScope.shared
        var entries: [ObjectEntry] = []
        for role in roles {
            let agent = try await system.agent(asked(role))
            let object = try DiscoverableObject.resolve(id: agent.id, using: system)
            await system.receptionist.checkIn(object, with: scope.virtualReceptionistKey)
            entries.append(
                ObjectEntry(
                    id: objectID(role), object: object, type: objectType,
                    description: objectDescription.description, scope: scope,
                    actions: objectDescription.actions.map { ObjectCatalog.signature($0.key, input: $0.value.input) }
                        .sorted()))
        }
        return entries
    }
}
