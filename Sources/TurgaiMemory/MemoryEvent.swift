#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Events in the memory section of one user's journal.
///
/// Facts change only when an extraction is committed: what was learned and what ended, decided by
/// ``Memory/reading(_:of:newID:)``. A committed extraction still records which messages it read,
/// even when nothing changed.
public indirect enum MemoryEvent: Codable, Sendable, Equatable {
    /// Logically forgets the active memory projection. Earlier journal events
    /// remain available to infrastructure readers, but replay after this
    /// boundary starts a fresh memory generation.
    case cleared(at: Date)
    case observationRecorded(MemoryObservation)
    /// They had a fact forgotten.
    case factForgotten(MemoryFactID)
    case extractionCommitted(MemoryExtractionCommit)
    /// The person turned remembering what they say on or off.
    case rememberingChanged(Remembering)
}

/// Whether what a person says is remembered. Off, nothing new is kept or extracted, and what's
/// remembered stays until it's forgotten.
public enum Remembering: String, Codable, Sendable, Equatable {
    case on
    case off
}

/// One atomic extraction result: the messages read, and what that changed in their memory.
/// Lifecycle events such as `cleared` cannot be nested.
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

/// What reading their messages changed in their memory.
public enum MemoryFactEvent: Codable, Sendable, Equatable {
    /// They said something new about themselves.
    case learned(MemoryFact)
    /// What they said made a fact untrue.
    case ended(MemoryFactID, Said)
}
