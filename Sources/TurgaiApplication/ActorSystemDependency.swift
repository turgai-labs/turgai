import DistributedCluster
import DurableWorkflows
import Hail
import Synchronization
import TurgaiDomain
import TurgaiPeople

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The narrowed slice of the node's actor system that tools and effects may
/// use.
///
/// Only the workflow and virtual-actor verbs Turgai actually needs are
/// reachable, and tests can substitute fakes without a node.
///
/// The access discipline follows swift-dependencies:
///
/// - The production facade is registered exactly once at the application
///   boundary with ``prepare(_:)``.
/// - Production code reads ``current`` ambiently and never wraps calls.
/// - ``withActorSystemDependency(_:operation:)`` exists only to override
///   behavior — in tests or deliberately scoped experiments.
///
/// The ambient read is what lets inert effect values (which cannot carry a
/// live client and whose `run` takes no parameters) reach the system. It is
/// process-wide and node-local: durable work firing later, possibly after a
/// restart, runs in a fresh process and must keep using its own
/// `context.system`, never this facade.
///
/// The narrowed slice of the node's actor system exposed to effect-backed
/// tools. Application actors must use their explicit `actorSystem` property.
/// This facade is intentionally not a general actor-system dependency; it
/// exists only at the tool/effect boundary.
///
/// `Effect` is a ceremonial ownership label. It does not alter the stored
/// capabilities or runtime behavior; it makes a tool call visibly name the
/// effect whose execution needs those capabilities. Keep this dependency in
/// tools and effects, not in application actors.
public struct ActorSystemDependency<Effect: ScopedEffect>: Sendable {
    public var virtualActors: VirtualActorActions

    public init(virtualActors: VirtualActorActions) {
        self.virtualActors = virtualActors
    }

    /// The facade over a live node, whose chats' agents answer with `models`.
    public static func live(on actorSystem: ClusterSystem, models: ChatModels) -> ActorSystemDependency<Effect> {
        ActorSystemDependency<Effect>(
            virtualActors: VirtualActorActions(
                resolveUser: { userID in
                    try await User.resolve(on: actorSystem, userID: userID)
                },
                notify: { conversationID, text in
                    try await Conversation.resolve(on: actorSystem, conversationID: conversationID).notify(text)
                },
                ask: { conversationID, question in
                    try await models.ask(question, in: conversationID, on: actorSystem)
                }
            )
        )
    }
}

/// Typed virtual-actor resolution. Deliberately not a generic `resolve`:
/// only the actors Turgai's tools actually address are exposed.
public struct VirtualActorActions: Sendable {
    public var resolveUser: @Sendable (TurgaiDomain.UserID) async throws -> User
    /// Says text in a conversation, as its connections deliver what it says.
    public var notify: @Sendable (ConversationID, String) async throws -> Void
    /// Asks the model of the agent that answers a conversation one question, on its own: what it
    /// answers.
    public var ask: @Sendable (ConversationID, String) async throws -> String

    public init(
        resolveUser: @escaping @Sendable (TurgaiDomain.UserID) async throws -> User,
        notify: @escaping @Sendable (ConversationID, String) async throws -> Void,
        ask: @escaping @Sendable (ConversationID, String) async throws -> String
    ) {
        self.resolveUser = resolveUser
        self.notify = notify
        self.ask = ask
    }
}

private enum ActorSystemDependencyStorage {
    struct Values: Sendable {
        let virtualActors: VirtualActorActions
    }

    /// Task-local override, set only by ``withActorSystemDependency(_:operation:)``.
    @TaskLocal
    static var override: Values?

    /// The production facade, registered once via ``ActorSystemDependency/prepare(_:)``.
    static let prepared = Mutex<Values?>(nil)
}

extension ActorSystemDependency {
    /// Registers the production facade. Called exactly once at the
    /// application boundary, before any tool or effect runs.
    public static func prepare(_ dependency: ActorSystemDependency<Effect>) {
        ActorSystemDependencyStorage.prepared.withLock { prepared in
            precondition(
                prepared == nil,
                "ActorSystemDependency.prepare must run exactly once, at the application boundary."
            )
            prepared = ActorSystemDependencyStorage.Values(virtualActors: dependency.virtualActors)
        }
    }

    /// The facade for the current context: the task-local override when one
    /// is installed, otherwise the registered production facade.
    public static var current: ActorSystemDependency<Effect> {
        if let override = ActorSystemDependencyStorage.override {
            return ActorSystemDependency(virtualActors: override.virtualActors)
        }
        guard let prepared = ActorSystemDependencyStorage.prepared.withLock({ $0 }) else {
            preconditionFailure(
                "ActorSystemDependency was read before prepare(_:) ran at the application boundary."
            )
        }
        return ActorSystemDependency(virtualActors: prepared.virtualActors)
    }
}

/// Overrides the actor-system facade for one operation. This exists to
/// change behavior — tests and deliberately scoped experiments. Production
/// code registers once with ``ActorSystemDependency/prepare(_:)`` and reads
/// ``ActorSystemDependency/current`` ambiently.
public func withActorSystemDependency<Effect: ScopedEffect, Result>(
    _ dependency: ActorSystemDependency<Effect>,
    operation: () async throws -> Result
) async rethrows -> Result {
    let values = ActorSystemDependencyStorage.Values(virtualActors: dependency.virtualActors)
    return try await ActorSystemDependencyStorage.$override.withValue(values) {
        try await operation()
    }
}
