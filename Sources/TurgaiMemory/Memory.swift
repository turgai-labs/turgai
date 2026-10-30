#if canImport(FoundationEssentials)
    import FoundationEssentials
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

/// A name in a person's memory, as it's compared: trimmed, lowercased, its spaces collapsed, so
/// `Lives in` and `lives  in` are the same name.
public struct MemoryName: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// `written`, as a name: `nil` when nothing's written.
    public init?(_ written: String) {
        let name = written.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty else { return nil }
        self.rawValue = name
    }

    public var description: String { rawValue }
}

/// Where a fact is in a person's memory: the names from them down, `lives in` or
/// `family › sister`. A fact is known by its path: a new value at the same path replaces it.
public struct MemoryPath: Hashable, Codable, Sendable, CustomStringConvertible {
    /// How deep a path goes, at most.
    public static let maximumDepth = 3

    public let names: [MemoryName]

    /// `written`, from the person down, as a path: `nil` when a name is empty, or there are none
    /// or too many.
    public init?(_ written: [String]) {
        let names = written.compactMap(MemoryName.init)
        guard names.count == written.count, (1...Self.maximumDepth).contains(names.count) else { return nil }
        self.names = names
    }

    public var description: String {
        names.map(\.rawValue).joined(separator: " › ")
    }
}

public enum MemoryFactStatus: Hashable, Codable, Sendable {
    case active
    case superseded(by: MemoryFactID)
    case forgotten
}

/// Something the person said about themselves, at its place in their memory, with the messages it
/// came from.
///
/// A newer value at the same path supersedes the older one, which is kept as superseded.
public struct MemoryFact: Hashable, Codable, Sendable {
    public let id: MemoryFactID
    public let path: MemoryPath
    public let value: String
    public private(set) var evidence: [ObservationID]
    public private(set) var confidence: Double
    public let observedAt: Date
    public private(set) var status: MemoryFactStatus

    public init(
        id: MemoryFactID = MemoryFactID(),
        path: MemoryPath,
        value: String,
        evidence: [ObservationID],
        confidence: Double,
        observedAt: Date,
        status: MemoryFactStatus = .active
    ) {
        self.id = id
        self.path = path
        self.value = value
        self.evidence = evidence
        self.confidence = min(max(confidence, 0), 1)
        self.observedAt = observedAt
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
    public let path: MemoryPath
    public let value: String
    public let evidence: [ObservationID]
    /// A short verbatim fragment from one of the referenced user
    /// observations. This is deliberately separate from the assistant
    /// response: tool output and generated text can provide context, but
    /// cannot establish a personal fact.
    public let supportingText: String
    public let confidence: Double
    public let observedAt: Date

    public init(
        path: MemoryPath,
        value: String,
        evidence: [ObservationID],
        supportingText: String,
        confidence: Double,
        observedAt: Date = Date()
    ) {
        self.path = path
        self.value = value
        self.evidence = evidence
        self.supportingText = supportingText
        self.confidence = min(max(confidence, 0), 1)
        self.observedAt = observedAt
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
