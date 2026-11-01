import Distributed
import DistributedCluster
import EventSourcing
import TurgaiDomain
import TurgaiMemory
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Durable state owned by one Turgai user.
///
/// This is intentionally made only from Turgai domain values. Telegram users,
/// Telegram profile fields, and other provider models stay in their channel
/// adapters and are never persisted here.
public struct UserRecord: Codable, Sendable, Equatable {
    public let userID: UserID
    public private(set) var memory: Memory

    /// What a new person has: nothing remembered, and remembering on, unless they're a guest.
    public init(userID: UserID) {
        self.userID = userID
        self.memory = Memory(remembering: userID.isGuest ? .off : .on)
    }

    public mutating func apply(_ event: UserEvent) {
        switch event {
        case .memory(let event):
            memory.apply(event)
        }
    }
}

/// The read model for one background extraction pass.
public struct MemoryExtractionSnapshot: Codable, Sendable {
    public let input: ExtractionInput
    /// Every stored observation, for verbatim candidate matching.
    public let evidence: [MemoryObservation]

    public var latestObservationSourceID: MemorySourceID? {
        Memory.latestObservation(in: evidence)?.sourceID
    }
}

public enum ExtractionOutcome: Codable, Sendable, Equatable {
    case committed(MemoryUpdate)
    case stale
    case alreadyHandled
}

/// Events in one person's journal: what they remember.
public enum UserEvent: Codable, Sendable, Equatable {
    case memory(MemoryEvent)
}

/// A durable user aggregate. The actor is deliberately provider-neutral: a
/// Telegram adapter resolves a Telegram participant to `UserID` and links it
/// here, but the actor never imports Telegram types.
@EventSourced
@VirtualActor
public distributed actor User {
    public typealias Event = UserEvent
    public typealias ActorSystem = ClusterSystem
    public typealias State = UserRecord
    public typealias Dependency = Config

    public struct Config: Codable, Sendable {
        public let userID: UserID

        public init(userID: UserID) {
            self.userID = userID
        }
    }

    public var state: UserRecord

    public let snapshotting: Snapshotting<UserEvent, UserRecord> = .every(
        numberOfEvents: 50,
        retention: .keepLast(2)
    )

    private let userID: UserID

    public init(actorSystem: ClusterSystem, dependency: Config) async throws {
        self.actorSystem = actorSystem
        self.userID = dependency.userID
        self.state = UserRecord(userID: dependency.userID)
        try await actorSystem.journal.register(
            actor: self,
            with: Self.persistenceID(for: dependency.userID)
        )
    }

    public static func actorID(for userID: UserID) -> VirtualActorID {
        VirtualActorID(rawValue: "user:\(userID.key)")
    }

    public static func persistenceID(for userID: UserID) -> String {
        "turgai-user-\(userID.key)"
    }

    public static func resolve(
        on actorSystem: ClusterSystem,
        userID: UserID
    ) async throws -> User {
        try await actorSystem.virtualActors.getActor(
            identifiedBy: actorID(for: userID),
            dependency: Config(userID: userID)
        )
    }

    /// Records a completed exchange once, keyed by its source message.
    /// Replayed turns cannot duplicate the evidence used by extraction.
    public distributed func recordObservation(_ observation: MemoryObservation) async throws {
        guard state.memory.accepts(observation),
            !state.memory.containsObservation(for: observation.sourceID)
        else { return }
        try await emit(event: .memory(.observationRecorded(observation)))
    }

    /// Applies the pure extraction decision as one memory journal event.
    public distributed func commitExtraction(
        _ input: ExtractionInput,
        candidates: [FactCandidate],
        expectedLatestSourceID: MemorySourceID
    ) async throws -> ExtractionOutcome {
        guard state.memory.latestObservationSourceID == expectedLatestSourceID else {
            return .stale
        }
        switch MemoryExtraction.decide(
            state: state.memory,
            input: input,
            candidates: candidates
        ) {
        case .stale:
            return .stale
        case .alreadyHandled:
            return .alreadyHandled
        case .commit(let commit):
            try await emit(event: .memory(.extractionCommitted(commit)))
            // `emit` persists and applies the event, but it suspends. A
            // reentrant `/forget` may therefore have established a newer
            // generation before this method resumes. Do not report a commit
            // that the current projection no longer contains.
            guard state.memory.generation == commit.generation,
                state.memory.latestObservationSourceID == expectedLatestSourceID,
                commit.processedSources.allSatisfy({
                    state.memory.containsObservation(for: $0)
                })
            else {
                return .stale
            }
            return .committed(
                MemoryUpdate(
                    factChanges: commit.changes.map(Self.change(from:))
                )
            )
        }
    }

    /// The state slice one extraction pass needs: an immutable input built
    /// from current state, plus the full evidence list for candidate
    /// matching. Conversation owns all extraction logic; User exposes reads.
    public distributed func extractionSnapshot() -> MemoryExtractionSnapshot {
        let pending = state.memory.observations.filter {
            state.memory.accepts($0) && !state.memory.isProcessed($0)
        }
        return MemoryExtractionSnapshot(
            input: ExtractionInput(
                observations: pending,
                generation: state.memory.generation,
                existingFacts: state.memory.currentFacts(),
                previousObservations: state.memory.recentObservations(limit: 32)
            ),
            evidence: state.memory.observations
        )
    }

    private static func change(from event: MemoryFactEvent) -> MemoryFactChange {
        switch event {
        case .factAccepted: .accepted
        case .factReinforced: .reinforced
        case .factSuperseded: .superseded
        }
    }

    /// What's remembered about them, as a recall answers it.
    public distributed func recalled() -> String {
        MemoryRetrieval.recalled(state.memory.tree)
    }

    /// Whether there's anything to recall: they remember, and something is remembered.
    public distributed func recallable() -> Bool {
        state.memory.remembering == .on && !state.memory.currentFacts().isEmpty
    }

    /// What's remembered about them, as they see it.
    public distributed func remembered() -> MemoryTree {
        state.memory.tree
    }

    /// Forgets the fact `id`: whether it was remembered.
    public distributed func forgetFact(_ id: MemoryFactID) async throws -> Bool {
        guard state.memory.currentFacts().contains(where: { $0.id == id }) else { return false }
        try await emit(event: .memory(.factForgotten(id)))
        return true
    }

    /// Whether what they say is kept for their memory.
    public distributed func currentRemembering() -> Remembering {
        state.memory.remembering
    }

    /// Turns keeping what they say for their memory on or off.
    public distributed func setRemembering(_ remembering: Remembering) async throws {
        guard state.memory.remembering != remembering else { return }
        try await emit(event: .memory(.rememberingChanged(remembering)))
    }

    public distributed func memoryGeneration() -> MemoryGeneration {
        state.memory.generation
    }

    /// Logically forgets all active memory and provenance retained by the
    /// projection. The journal remains intact; replay sees the clear boundary
    /// and starts a new generation.
    public distributed func forgetMemory() async throws -> Int {
        let count = state.memory.currentFacts().count
        try await emit(event: .memory(.cleared(at: Date())))
        return count
    }

    public distributed func currentRecord() -> UserRecord {
        state
    }

    public func handleEvent(_ event: UserEvent) {
        state.apply(event)
    }
}
