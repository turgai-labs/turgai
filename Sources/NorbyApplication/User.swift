import Distributed
import DistributedCluster
import EventSourcing
import Foundation
import NorbyDomain
import NorbyMemory
import VirtualActors

/// Durable state owned by one Norby user.
///
/// This is intentionally made only from Norby domain values. Telegram users,
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
        self.participantLinks = try container.decodeIfPresent(
            [UserParticipantLink].self,
            forKey: .participantLinks
        ) ?? []
        // Older User snapshots predate semantic memory.
        self.memory = try container.decodeIfPresent(
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
        "norby-user-\(userID.rawValue)"
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

    /// Idempotently associates a channel participant with this Norby user.
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

    /// Records one raw observation. This is idempotent by source ID.
    public distributed func recordObservation(
        _ observation: MemoryObservation
    ) async throws -> ObservationID {
        let reference = try await ensureObservation(observation)
        return reference.id
    }

    /// Records a completed turn and applies the supplied extractor output.
    ///
    /// The observation is persisted before candidates are evaluated. If a
    /// process stops between those events, retrying still evaluates the same
    /// candidates; policy makes already-applied evidence a no-op.
    public distributed func recordCompletedObservation(
        _ observation: MemoryObservation
    ) async throws -> MemoryUpdate {
        try await recordCompletedObservation(
            observation,
            proposals: MemoryExtractor.extract(from: observation).map(MemoryProposal.add)
        )
    }

    /// Persists a completed observation and applies candidates produced by an
    /// application-side extractor. This overload keeps the original domain
    /// boundary for callers that only produce additions.
    public distributed func recordCompletedObservation(
        _ observation: MemoryObservation,
        candidates: [FactCandidate]
    ) async throws -> MemoryUpdate {
        try await recordCompletedObservation(
            observation,
            proposals: candidates.map(MemoryProposal.add)
        )
    }

    /// Persists a completed observation and applies extractor proposals.
    /// Extraction is deliberately outside this aggregate; this method owns
    /// only durable memory policy and journaling.
    public distributed func recordCompletedObservation(
        _ observation: MemoryObservation,
        proposals: [MemoryProposal]
    ) async throws -> MemoryUpdate {
        let reference = try await ensureObservation(observation)
        let evidencedProposals = proposals.map {
            Self.addEvidence(
                from: $0,
                observationID: reference.id,
                replacingObservationID: observation.id
            )
        }

        var changes: [MemoryFactChange] = []
        for proposal in evidencedProposals {
            if let change = try await recordProposalInJournal(proposal) {
                changes.append(change)
            }
        }
        return MemoryUpdate(
            observationRecorded: reference.recorded,
            factChanges: changes
        )
    }

    /// Applies deterministic policy to an extractor or explicit-memory
    /// proposal. The actor creates the fact identity; policy remains pure.
    public distributed func recordCandidate(_ candidate: FactCandidate) async throws -> MemoryUpdate {
        let change = try await recordProposalInJournal(.add(candidate))
        return MemoryUpdate(factChanges: change.map { [$0] } ?? [])
    }

    /// Applies a model-directed proposal with provenance from the current
    /// conversation turn. Both additions and revisions use the same policy as
    /// automatic extraction.
    public distributed func applyMemoryProposal(
        _ proposal: MemoryProposal,
        observation: MemoryObservation
    ) async throws -> MemoryUpdate {
        let reference = try await ensureObservation(observation)
        let evidencedProposal = Self.addEvidence(
            from: proposal,
            observationID: reference.id,
            replacingObservationID: observation.id
        )

        let change = try await recordProposalInJournal(evidencedProposal)
        return MemoryUpdate(
            observationRecorded: reference.recorded,
            factChanges: change.map { [$0] } ?? []
        )
    }

    /// Compatibility entry point for callers that only have a candidate.
    /// New callers should use ``applyMemoryProposal(_:observation:)`` so the
    /// source conversation turn is retained.
    public distributed func remember(_ candidate: FactCandidate) async throws -> MemoryUpdate {
        let observation = MemoryObservation(
            sourceID: MemorySourceID(),
            text: "Explicit memory request: \(candidate.predicate) = \(candidate.value.rendered)",
            observedAt: candidate.observedAt
        )
        return try await applyMemoryProposal(
            .add(candidate),
            observation: observation
        )
    }

    private func ensureObservation(
        _ observation: MemoryObservation
    ) async throws -> (id: ObservationID, recorded: Bool) {
        if let existing = state.memory.observations.first(where: {
            $0.sourceID == observation.sourceID
        }) {
            if existing.response == nil, let response = observation.response {
                try await emit(
                    event: .memory(
                        .observationCompleted(
                            sourceID: existing.sourceID,
                            response: response
                        )
                    )
                )
            }
            return (existing.id, false)
        }

        try await emit(event: .memory(.observationRecorded(observation)))
        return (observation.id, true)
    }

    private func recordProposalInJournal(
        _ proposal: MemoryProposal
    ) async throws -> MemoryFactChange? {
        let alreadyApplied: Bool
        switch proposal {
        case .add(let candidate):
            alreadyApplied = state.memory.facts.contains { fact in
                fact.namespace == candidate.namespace
                    && fact.predicate == candidate.predicate
                    && fact.value == candidate.value
                    && candidate.evidence.allSatisfy(fact.evidence.contains)
            }
        case .revise(let factID, let candidate):
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

    private static func addEvidence(
        from proposal: MemoryProposal,
        observationID: ObservationID,
        replacingObservationID: ObservationID? = nil
    ) -> MemoryProposal {
        func withEvidence(_ candidate: FactCandidate) -> FactCandidate {
            var evidence = candidate.evidence
            if let replacingObservationID, replacingObservationID != observationID {
                evidence.removeAll { $0 == replacingObservationID }
            }
            if !evidence.contains(observationID) {
                evidence.append(observationID)
            }
            return FactCandidate(
                namespace: candidate.namespace,
                predicate: candidate.predicate,
                value: candidate.value,
                evidence: evidence,
                confidence: candidate.confidence,
                importance: candidate.importance,
                stability: candidate.stability,
                observedAt: candidate.observedAt,
                validUntil: candidate.validUntil
            )
        }

        switch proposal {
        case .add(let candidate):
            return .add(withEvidence(candidate))
        case .revise(let factID, let candidate):
            return .revise(factID: factID, candidate: withEvidence(candidate))
        }
    }

    public distributed func memoryInstruction(for text: String) -> String? {
        let facts = MemoryRetrieval.facts(
            from: state.memory,
            matching: MemoryQuery(text: text)
        )
        return MemoryRetrieval.systemInstruction(for: facts)
    }

    public distributed func currentRecord() -> UserRecord {
        state
    }

    public func handleEvent(_ event: UserEvent) {
        state.apply(event)
    }
}
