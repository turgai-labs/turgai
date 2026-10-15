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
    public private(set) var participantLinks: [UserParticipantLink]
    public private(set) var memory: MemoryProjection

    public init(
        userID: UserID,
        participantLinks: [UserParticipantLink] = [],
        memory: MemoryProjection = MemoryProjection()
    ) {
        self.userID = userID
        self.participantLinks = participantLinks
        self.memory = memory
    }

    private enum CodingKeys: String, CodingKey {
        case userID
        case participantLinks
        case memory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.userID = try container.decode(UserID.self, forKey: .userID)
        self.participantLinks =
            try container.decodeIfPresent(
                [UserParticipantLink].self,
                forKey: .participantLinks
            ) ?? []
        // Older User snapshots predate semantic memory.
        self.memory =
            try container.decodeIfPresent(
                MemoryProjection.self,
                forKey: .memory
            ) ?? MemoryProjection()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userID, forKey: .userID)
        try container.encode(participantLinks, forKey: .participantLinks)
        try container.encode(memory, forKey: .memory)
    }

    public func isLinked(to participantID: ParticipantID) -> Bool {
        participantLinks.contains { $0.participantID == participantID }
    }

    public mutating func apply(_ event: UserEvent) {
        switch event {
        case .participantLinked(let link, _):
            guard !participantLinks.contains(link) else { return }
            participantLinks.append(link)
        case .participantUnlinked(let participantID, _):
            participantLinks.removeAll { $0.participantID == participantID }
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
        MemoryProjection.latestObservation(in: evidence)?.sourceID
    }
}

public enum ExtractionOutcome: Codable, Sendable, Equatable {
    case committed(MemoryUpdate)
    case stale
    case alreadyHandled
}

/// Events in one user's journal. Memory facts will be added beside these
/// identity events later; they will not require a second user store.
public enum UserEvent: Codable, Sendable, Equatable {
    case participantLinked(UserParticipantLink, at: Date)
    case participantUnlinked(ParticipantID, at: Date)
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
        VirtualActorID(rawValue: "user:\(userID.rawValue)")
    }

    public static func persistenceID(for userID: UserID) -> String {
        "turgai-user-\(userID.rawValue)"
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

    /// Idempotently associates a channel participant with this Turgai user.
    /// The initial identity policy creates one User per participant; a future
    /// consented account-linking flow can call this for several participants.
    public distributed func link(participantID: ParticipantID) async throws {
        guard !state.isLinked(to: participantID) else { return }
        try await emit(
            event: .participantLinked(
                UserParticipantLink(userID: userID, participantID: participantID),
                at: Date()
            )
        )
    }

    public distributed func unlink(participantID: ParticipantID) async throws {
        guard state.isLinked(to: participantID) else { return }
        try await emit(event: .participantUnlinked(participantID, at: Date()))
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
        proposals: [MemoryProposal],
        expectedLatestSourceID: MemorySourceID
    ) async throws -> ExtractionOutcome {
        guard state.memory.latestObservationSourceID == expectedLatestSourceID else {
            return .stale
        }
        switch MemoryExtraction.decide(
            state: state.memory,
            input: input,
            proposals: proposals
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
                existingFacts: Array(state.memory.currentFacts().suffix(32)),
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

    private func recordProposalInJournal(
        _ proposal: MemoryProposal
    ) async throws -> MemoryFactChange? {
        let candidate: FactCandidate
        switch proposal {
        case .add(let value), .revise(_, let value):
            candidate = value
        }
        guard MemoryEvidence.supports(candidate, in: state.memory.observations) else {
            return nil
        }

        let alreadyApplied: Bool
        switch proposal {
        case .add:
            alreadyApplied = state.memory.facts.contains { fact in
                fact.namespace == candidate.namespace
                    && fact.predicate == candidate.predicate
                    && fact.value == candidate.value
                    && candidate.evidence.allSatisfy(fact.evidence.contains)
            }
        case .revise(let factID, _):
            alreadyApplied = state.memory.facts.contains { fact in
                fact.id != factID
                    && fact.namespace == candidate.namespace
                    && fact.predicate == candidate.predicate
                    && fact.value == candidate.value
                    && candidate.evidence.allSatisfy(fact.evidence.contains)
            }
        }
        guard !alreadyApplied else { return nil }

        let decision = MemoryPolicy().decide(
            proposal: proposal,
            against: state.memory.facts,
            factID: MemoryFactID()
        )
        guard let event = decision.event else { return nil }
        try await emit(event: .memory(event))

        switch decision {
        case .accepted:
            return .accepted
        case .reinforced:
            return .reinforced
        case .superseded:
            return .superseded
        case .rejected:
            return nil
        }
    }

    /// What's remembered about `topic`, as a recall answers it.
    public distributed func recall(_ topic: String) -> String {
        MemoryRetrieval.recalled(MemoryRetrieval.facts(from: state.memory, matching: MemoryQuery(text: topic)))
    }

    /// Returns a bounded view for explicit user inspection. The journal and
    /// projection remain owned by this aggregate; callers cannot request an
    /// unbounded memory dump through the distributed API.
    public distributed func currentMemoryFacts(limit: Int = 20) -> [MemoryFact] {
        state.memory.currentFacts(limit: limit)
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
