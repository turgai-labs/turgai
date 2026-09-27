#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Events in the memory section of one user's journal.
///
/// Facts are proposals over observations, not direct mutations. Rejected
/// Rejected candidates produce no fact-level event. A completed extraction
/// still records which source messages were examined, even when no fact was
/// accepted.
public indirect enum MemoryEvent: Codable, Sendable, Equatable {
    /// Logically forgets the active memory projection. Earlier journal events
    /// remain available to infrastructure readers, but replay after this
    /// boundary starts a fresh memory generation.
    case cleared(at: Date)
    case observationRecorded(MemoryObservation)
    case factAccepted(MemoryFact)
    case factReinforced(MemoryFactID, evidence: [ObservationID], confidence: Double)
    /// One atomic event: the old fact becomes `superseded(by:)` and the
    /// replacement fact is appended as active.
    case factSuperseded(MemoryFactID, by: MemoryFact)
    case factExpired(MemoryFactID)
    case factForgotten(MemoryFactID)
    case extractionCommitted(MemoryExtractionCommit)
}

/// One atomic extraction result: processed sources plus any accepted
/// fact-level changes. Lifecycle events such as `cleared` cannot be nested.
public struct MemoryExtractionCommit: Codable, Sendable, Equatable {
    public let generation: MemoryGeneration
    public let processedSources: [MemorySourceID]
    public let observations: [MemoryObservation]
    public let changes: [MemoryFactEvent]

    public init(
        generation: MemoryGeneration,
        processedSources: [MemorySourceID],
        observations: [MemoryObservation],
        changes: [MemoryFactEvent]
    ) {
        self.generation = generation
        self.processedSources = processedSources
        self.observations = observations
        self.changes = changes
    }
}

public enum MemoryFactEvent: Codable, Sendable, Equatable {
    case factAccepted(MemoryFact)
    case factReinforced(MemoryFactID, evidence: [ObservationID], confidence: Double)
    case factSuperseded(MemoryFactID, by: MemoryFact)
}
