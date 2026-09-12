import Distributed
import DistributedCluster
import EventSourcing
import NorbyDomain
import NorbyMemory
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

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

    /// Records user evidence before model work begins. Facts are not inferred
    /// here; this event only makes the statement durable for a later unified
    /// compaction report.
    public distributed func recordObservation(_ observation: MemoryObservation) async throws {
        guard state.memory.accepts(observation),
            !state.memory.containsObservation(for: observation.sourceID)
        else { return }
        try await emit(event: .memory(.observationRecorded(observation)))
    }

    /// Applies the pure extraction decision as one memory journal event.
    public distributed func commitExtraction(
        _ input: ExtractionInput,
        proposals: [MemoryProposal]
    ) async throws -> ExtractionOutcome {
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
                commit.processedSources.allSatisfy({
                    state.memory.containsObservation(for: $0)
                })
            else {
                return .stale
            }
            return .committed(
                MemoryUpdate(
                    observationRecorded: true,
                    factChanges: commit.changes.map(Self.change(from:))
                )
            )
        }
    }

    /// Reconciles the memory candidates embedded in one conversation
    /// compaction report. Evidence is resolved here, where the User aggregate
    /// owns the durable observation history; the conversation never interprets
    /// memory candidates.
    public distributed func commitCompactionMemories(
        observations: [MemoryObservation],
        candidates: [ConversationCompactionMemoryCandidate]
    ) async throws -> ExtractionOutcome {
        let pending = (state.memory.observations + observations).reduce(into: [MemoryObservation]()) {
            result, observation in
            guard state.memory.accepts(observation),
                !state.memory.isProcessed(observation),
                !result.contains(where: { $0.sourceID == observation.sourceID })
            else { return }
            result.append(observation)
        }
        guard !pending.isEmpty else { return .alreadyHandled }

        let input = ExtractionInput(
            observations: pending,
            generation: state.memory.generation,
            existingFacts: Array(state.memory.currentFacts().suffix(32)),
            previousObservations: state.memory.recentObservations(limit: 32)
        )
        let evidence = state.memory.observations + pending
        let proposals = candidates.compactMap { candidate in
            Self.proposal(
                from: candidate,
                evidence: evidence,
                observedAt: pending.last?.observedAt
            )
        }
        return try await commitExtraction(input, proposals: proposals)
    }

    private static func proposal(
        from candidate: ConversationCompactionMemoryCandidate,
        evidence: [MemoryObservation],
        observedAt: Date?
    ) -> MemoryProposal? {
        let quote = normalize(candidate.supportingText)
        guard !quote.isEmpty else { return nil }
        let predicate = candidate.predicate.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = candidate.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !predicate.isEmpty, !rawValue.isEmpty,
            predicate.count <= 500, rawValue.count <= 500
        else { return nil }
        let matches = evidence.filter { normalize($0.text).contains(quote) }
        guard matches.count == 1, let source = matches.first,
            let namespace = MemoryNamespace(rawValue: candidate.namespace),
            let stability = MemoryStability(rawValue: candidate.stability),
            let observedAt
        else { return nil }

        let value: MemoryValue
        switch candidate.valueKind {
        case "text": value = .text(rawValue)
        case "person": value = .person(rawValue)
        case "place": value = .place(rawValue)
        case "date":
            guard let date = ISO8601DateFormatter().date(from: rawValue) else { return nil }
            value = .date(date)
        case "preference":
            guard let preference = Bool(rawValue) else { return nil }
            value = .preference(preference)
        default: return nil
        }

        let fact = FactCandidate(
            namespace: namespace,
            predicate: predicate,
            value: value,
            evidence: [source.id],
            supportingText: candidate.supportingText,
            confidence: candidate.confidence,
            importance: candidate.importance,
            stability: stability,
            observedAt: observedAt
        )
        return .add(fact)
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func change(from event: MemoryFactEvent) -> MemoryFactChange {
        switch event {
        case .factAccepted: .accepted
        case .factReinforced: .reinforced
        case .factSuperseded: .superseded
        }
    }

    /// Applies deterministic policy to an extractor or explicit-memory
    /// proposal. The actor creates the fact identity; policy remains pure.
    public distributed func recordCandidate(_ candidate: FactCandidate) async throws -> MemoryUpdate {
        let change = try await recordProposalInJournal(.add(candidate))
        return MemoryUpdate(factChanges: change.map { [$0] } ?? [])
    }

    /// Applies a model-directed proposal. The caller supplies provenance in
    /// the proposal, so direct tool writes and background extraction use the
    /// same policy and evidence invariant.
    public distributed func applyMemoryProposal(
        _ proposal: MemoryProposal,
        observation: MemoryObservation,
        expectedGeneration: MemoryGeneration? = nil
    ) async throws -> MemoryUpdate {
        guard
            expectedGeneration == nil
                || expectedGeneration == state.memory.generation
        else {
            return MemoryUpdate()
        }
        guard state.memory.accepts(observation) else { return MemoryUpdate() }

        let reference = try await ensureObservation(observation)

        let change = try await recordProposalInJournal(proposal)
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
        let evidencedCandidate = FactCandidate(
            namespace: candidate.namespace,
            predicate: candidate.predicate,
            value: candidate.value,
            evidence: [observation.id],
            supportingText: observation.text,
            confidence: candidate.confidence,
            importance: candidate.importance,
            stability: candidate.stability,
            observedAt: candidate.observedAt,
            validUntil: candidate.validUntil
        )
        return try await applyMemoryProposal(
            .add(evidencedCandidate),
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

    public distributed func memoryInstruction(for text: String) -> String? {
        let facts = MemoryRetrieval.facts(
            from: state.memory,
            matching: MemoryQuery(text: text)
        )
        return MemoryRetrieval.systemInstruction(for: facts)
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
