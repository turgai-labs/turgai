#if canImport(FoundationEssentials)
    import FoundationEssentials
    import FoundationInternationalization
#else
    import Foundation
#endif

public struct MemorySourceID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ObservationID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct MemoryFactID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Monotonic generation of a user's logical memory. A background extraction
/// captures this value before it starts; a later `/forget` advances it so the
/// old extraction cannot write its result back into the cleared projection.
public struct MemoryGeneration: Hashable, Codable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64 = 0) {
        self.rawValue = rawValue
    }

    public static let initial = MemoryGeneration()

    public func advancing() -> MemoryGeneration {
        MemoryGeneration(rawValue: rawValue &+ 1)
    }
}

/// A raw, unfiltered record of one user message and its exchange context.
/// The assistant response can explain a short answer, but only user text is
/// evidence for a memory. The subject is implicit: each observation lives in
/// exactly one user's journal.
public struct MemoryObservation: Hashable, Codable, Sendable {
    public let id: ObservationID
    public let sourceID: MemorySourceID
    public let text: String
    public let response: String?
    public let observedAt: Date

    public init(
        id: ObservationID = ObservationID(),
        sourceID: MemorySourceID,
        text: String,
        response: String? = nil,
        observedAt: Date
    ) {
        self.id = id
        self.sourceID = sourceID
        self.text = text
        self.response = response
        self.observedAt = observedAt
    }
}

public enum MemoryNamespace: String, Codable, Sendable, CaseIterable {
    case profile
    case preference
    case relationship
    case project
    case environment
}

/// Typed enough to distinguish a place, person, date, boolean preference,
/// and free text — no single prose profile blob.
public enum MemoryValue: Hashable, Codable, Sendable {
    case text(String)
    case person(String)
    case place(String)
    case date(Date)
    case preference(Bool)

    public var rendered: String {
        switch self {
        case .text(let value): value
        case .person(let value): value
        case .place(let value): value
        case .date(let value): value.formatted(date: .abbreviated, time: .omitted)
        case .preference(let value): value ? "yes" : "no"
        }
    }
}

/// How likely a fact is to change. Drives supersession and expiration.
public enum MemoryStability: String, Codable, Sendable, CaseIterable {
    /// Low-value short-lived context (for example "checking the weather in
    /// Munich this week"). Expires quickly.
    case transient
    /// Currently true but expected to change on its own.
    case situational
    /// A durable attribute that can still change (residence, job, pets).
    case mutable
    /// Effectively permanent (birth date, given name).
    case stable
}

public enum MemoryFactStatus: Hashable, Codable, Sendable {
    case active
    case superseded(by: MemoryFactID)
    case expired
    case forgotten
}

/// A durable statement about the user, derived from observations.
///
/// Contradictory facts are retained with status and validity ranges; a newer
/// residence does not erase the older one.
public struct MemoryFact: Hashable, Codable, Sendable {
    public let id: MemoryFactID
    public let namespace: MemoryNamespace
    public let predicate: String
    public let value: MemoryValue
    public private(set) var evidence: [ObservationID]
    public private(set) var confidence: Double
    public let importance: Double
    public let stability: MemoryStability
    public let observedAt: Date
    public let validFrom: Date?
    public let validUntil: Date?
    public private(set) var status: MemoryFactStatus

    public init(
        id: MemoryFactID = MemoryFactID(),
        namespace: MemoryNamespace,
        predicate: String,
        value: MemoryValue,
        evidence: [ObservationID],
        confidence: Double,
        importance: Double,
        stability: MemoryStability,
        observedAt: Date,
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        status: MemoryFactStatus = .active
    ) {
        self.id = id
        self.namespace = namespace
        self.predicate = predicate
        self.value = value
        self.evidence = evidence
        self.confidence = min(max(confidence, 0), 1)
        self.importance = min(max(importance, 0), 1)
        self.stability = stability
        self.observedAt = observedAt
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.status = status
    }

    mutating func reinforce(evidence: [ObservationID], confidence: Double) {
        let merged = self.evidence + evidence.filter { !self.evidence.contains($0) }
        self.evidence = merged
        self.confidence = min(max(confidence, 0), 1)
    }

    mutating func transition(to status: MemoryFactStatus) {
        self.status = status
    }
}

/// The extractor's proposal. Carries no identity and no authority: the
/// deterministic ``MemoryPolicy`` decides what becomes a durable fact, while
/// ``MemoryEvidence`` validates that its provenance is user-authored.
public struct FactCandidate: Hashable, Codable, Sendable {
    public let namespace: MemoryNamespace
    public let predicate: String
    public let value: MemoryValue
    public let evidence: [ObservationID]
    /// A short verbatim fragment from one of the referenced user
    /// observations. This is deliberately separate from the assistant
    /// response: tool output and generated text can provide context, but
    /// cannot establish a personal fact.
    public let supportingText: String
    public let confidence: Double
    public let importance: Double
    public let stability: MemoryStability
    public let observedAt: Date
    public let validUntil: Date?

    public init(
        namespace: MemoryNamespace,
        predicate: String,
        value: MemoryValue,
        evidence: [ObservationID],
        supportingText: String,
        confidence: Double,
        importance: Double,
        stability: MemoryStability,
        observedAt: Date = Date(),
        validUntil: Date? = nil
    ) {
        self.namespace = namespace
        self.predicate = predicate
        self.value = value
        self.evidence = evidence
        self.supportingText = supportingText
        self.confidence = min(max(confidence, 0), 1)
        self.importance = min(max(importance, 0), 1)
        self.stability = stability
        self.observedAt = observedAt
        self.validUntil = validUntil
    }
}

/// Pure validation of proposal provenance. The referenced observation IDs
/// identify possible sources; the supporting text proves that at least one of
/// those sources is the user's own message. Observation responses are never
/// searched, so generated replies and tool results cannot become evidence.
public enum MemoryEvidence {
    public static func supports(
        _ candidate: FactCandidate,
        in observations: [MemoryObservation]
    ) -> Bool {
        let quote = normalized(candidate.supportingText)
        guard !candidate.evidence.isEmpty, !quote.isEmpty else { return false }
        guard
            candidate.evidence.allSatisfy({ evidenceID in
                observations.contains { $0.id == evidenceID }
            })
        else {
            return false
        }

        return observations.contains { observation in
            candidate.evidence.contains(observation.id)
                && normalized(observation.text).contains(quote)
        }
    }

    private static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

/// A model or application proposal over one user's memory.
///
/// An addition that contradicts an active fact with the same namespace and
/// predicate supersedes it; ``MemoryPolicy`` resolves the contradiction
/// deterministically. A revision must identify the active fact it is
/// correcting; ``MemoryPolicy`` validates that identity before producing a
/// journal event.
public enum MemoryProposal: Hashable, Codable, Sendable {
    case add(FactCandidate)
    case revise(factID: MemoryFactID, candidate: FactCandidate)
}

/// The immutable input captured for one memory extraction.
public struct ExtractionInput: Codable, Sendable, Equatable {
    public let observations: [MemoryObservation]
    public let generation: MemoryGeneration
    public let existingFacts: [MemoryFact]
    public let previousObservations: [MemoryObservation]

    public init(
        observations: [MemoryObservation],
        generation: MemoryGeneration,
        existingFacts: [MemoryFact],
        previousObservations: [MemoryObservation] = []
    ) {
        self.observations = observations
        self.generation = generation
        self.existingFacts = existingFacts
        self.previousObservations = previousObservations
    }

    /// The conversation context in the order in which exchanges occurred.
    /// Separate storage for current and preceding observations must not become
    /// prompt order.
    public var chronologicalObservations: [MemoryObservation] {
        (previousObservations + observations)
            .enumerated()
            .sorted {
                if $0.element.observedAt != $1.element.observedAt {
                    return $0.element.observedAt < $1.element.observedAt
                }
                if $0.element.sourceID != $1.element.sourceID {
                    return $0.element.sourceID.rawValue.uuidString < $1.element.sourceID.rawValue.uuidString
                }
                return $0.offset < $1.offset
            }
            .map(\.element)
    }
}

public enum MemoryFactChange: String, Codable, Sendable, Equatable {
    case accepted
    case reinforced
    case superseded
}

/// The transient result of one memory write. It is returned to the
/// application shell so a channel can acknowledge meaningful changes without
/// coupling the memory journal to any transport.
public struct MemoryUpdate: Hashable, Codable, Sendable, Equatable {
    public let observationRecorded: Bool
    public let factChanges: [MemoryFactChange]

    public init(
        observationRecorded: Bool = false,
        factChanges: [MemoryFactChange] = []
    ) {
        self.observationRecorded = observationRecorded
        self.factChanges = factChanges
    }

    /// Number of fact changes represented by this update, not the total number
    /// of facts currently stored in the projection.
    public var changedFactCount: Int {
        factChanges.count
    }

    public var newFactCount: Int {
        factChanges.count { $0 == .accepted }
    }

    /// Number of existing facts reinforced or superseded by this update.
    /// This is intentionally scoped to this update, not the whole memory.
    public var updatedFactCount: Int {
        factChanges.count { $0 != .accepted }
    }

    public var shouldNotify: Bool {
        !factChanges.isEmpty
    }
}
