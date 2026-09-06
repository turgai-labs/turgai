import Foundation

/// Events in the memory section of one user's journal.
///
/// Facts are proposals over observations, not direct mutations. Rejected
/// candidates produce no event at all, so the journal remains the complete
/// audit trail of what was accepted, reinforced, superseded, or removed.
public enum MemoryEvent: Codable, Sendable, Equatable {
    /// Logically forgets the active memory projection. Earlier journal events
    /// remain available to infrastructure readers, but replay after this
    /// boundary starts a fresh memory generation.
    case cleared(at: Date)
    case observationRecorded(MemoryObservation)
    /// Completes a previously recorded source without changing its identity.
    case observationCompleted(sourceID: MemorySourceID, response: String)
    case factAccepted(MemoryFact)
    case factReinforced(MemoryFactID, evidence: [ObservationID], confidence: Double)
    /// One atomic event: the old fact becomes `superseded(by:)` and the
    /// replacement fact is appended as active.
    case factSuperseded(MemoryFactID, by: MemoryFact)
    case factExpired(MemoryFactID)
    case factForgotten(MemoryFactID)
}
