import Distributed
import DistributedCluster
import EventSourcing
import SQLiteNIO
import TurgaiDomain
import TurgaiMemory
import TurgaiPeople
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum MemoryNoticesError: Error, Equatable, Sendable {
    /// A journal that isn't a person's.
    case notAPerson(PersistenceID)
}

/// That what's remembered about a person changed: what's remembered is read again.
public struct MemoryChanged: Codable, Sendable, Equatable {
    public let person: UserID
}

/// What's remembered about each person changing, as it follows their memory events: each follower
/// subscribes for a person and pulls each change. One in the cluster, run where the journal can be
/// read, as its projection must be.
public distributed actor MemoryNotices: ClusterSingleton {
    public typealias ActorSystem = ClusterSystem

    /// What the cluster knows it by.
    public static let singletonName = "turgai-memory-notices"

    private let storage: ProjectionOffset
    /// The journal the memory events are read from: the concrete store, on this node.
    private let journal: any EventStore
    /// The projection, while it's the cluster's.
    private var following: Task<Void, Never>?
    /// Who follows each person's memory: a subscriber each, and whose they follow.
    private var pulls = Pulls<MemoryChanged>()
    private var followers: [UUID: UserID] = [:]

    public init(actorSystem: ClusterSystem, storage: ProjectionOffset, journal: any EventStore) {
        self.actorSystem = actorSystem
        self.storage = storage
        self.journal = journal
    }

    /// What's remembered about `person` changing, from now on, `for await change in subscription`.
    public nonisolated func subscription(for person: UserID) async throws -> Subscription<MemoryChanged> {
        let subscriber = UUID()
        try await subscribe(subscriber, to: person)
        return Subscription(subscriber, pull: { try await self.next(for: $0) }, leave: { try await self.leave($0) })
    }

    distributed func subscribe(_ subscriber: UUID, to person: UserID) {
        pulls.subscribe(subscriber)
        followers[subscriber] = person
    }

    /// `subscriber`'s next change: from its backlog, or the next one told. `nil` once it's left.
    distributed func next(for subscriber: UUID) async -> MemoryChanged? {
        switch pulls.take(subscriber) {
        case .element(let change): return change
        case .ended: return nil
        case .empty: return await withCheckedContinuation { pulls.park(subscriber, $0) }
        }
    }

    distributed func leave(_ subscriber: UUID) {
        pulls.leave(subscriber)
        followers.removeValue(forKey: subscriber)
    }

    /// `person`'s followers told their memory changed, when `event` changes it.
    private func tell(_ person: UserID, about event: UserEvent) async {
        guard case .memory(let event) = event, event.changesWhatsRemembered else { return }
        pulls.tell(MemoryChanged(person: person)) { followers[$0] == person }
    }

    /// Follows the memory events while it's the cluster's.
    public func activateSingleton() async {
        following = Task {
            await Projection<UserEvent>(tag: .memory).runRestarting(
                on: journal,
                offset: { try await self.storage.read() },
                process: { envelope in
                    guard let person = User.userID(persistenceID: envelope.persistenceID) else {
                        throw MemoryNoticesError.notAPerson(envelope.persistenceID)
                    }
                    try await self.storage.keep(envelope.offset)
                    await self.tell(person, about: envelope.event)
                },
                failed: { error in
                    self.actorSystem.log.error(
                        "Memory notices failed to follow the memory events; they start again shortly",
                        metadata: ["error": .string(String(describing: error))])
                })
        }
    }

    public func passivateSingleton() async {
        following?.cancel()
        following = nil
    }
}
