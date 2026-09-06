import Foundation

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

/// A raw, unfiltered record of one conversation turn.
///
/// The response is optional while the turn is running. Once available, the
/// pair of user text and assistant response is stored together because many
/// facts only exist across an exchange: an assistant's question ("what is his
/// name?") gives meaning to the user's next answer. The subject is implicit —
/// an observation lives in exactly one user's journal.
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
/// deterministic ``MemoryPolicy`` decides what becomes a durable fact.
public struct FactCandidate: Hashable, Codable, Sendable {
    public let namespace: MemoryNamespace
    public let predicate: String
    public let value: MemoryValue
    public let evidence: [ObservationID]
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
        self.confidence = min(max(confidence, 0), 1)
        self.importance = min(max(importance, 0), 1)
        self.stability = stability
        self.observedAt = observedAt
        self.validUntil = validUntil
    }
}

/// A model or application proposal over one user's memory.
///
/// Additions do not replace a different fact with the same predicate. A
/// revision must identify the active fact it is correcting; ``MemoryPolicy``
/// validates that identity before producing a journal event.
public enum MemoryProposal: Hashable, Codable, Sendable {
    case add(FactCandidate)
    case revise(factID: MemoryFactID, candidate: FactCandidate)
}

/// The bounded context supplied to a model-backed memory extractor.
public struct MemoryExtractionContext: Sendable {
    public let observation: MemoryObservation
    public let previousObservations: [MemoryObservation]
    public let existingFacts: [MemoryFact]

    public init(
        observation: MemoryObservation,
        previousObservations: [MemoryObservation] = [],
        existingFacts: [MemoryFact] = []
    ) {
        self.observation = observation
        self.previousObservations = previousObservations
        self.existingFacts = existingFacts
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
