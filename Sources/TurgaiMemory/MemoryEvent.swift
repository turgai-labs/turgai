import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Events in the memory section of one user's journal.
///
/// Facts change only when an extraction is committed: what was learned and what ended, decided by
/// ``Memory/reading(_:of:newID:)``. A committed extraction still records how far into its
/// conversation it read, even when nothing changed.
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

    /// Whether it changes what they see of their memory: what's remembered, or whether they're
    /// remembered. A message kept for reading, or a read that kept nothing, doesn't.
    public var changesWhatsRemembered: Bool {
        switch self {
        case .cleared, .factForgotten, .rememberingChanged: true
        case .extractionCommitted(let commit): !commit.changes.isEmpty
        case .observationRecorded: false
        }
    }
}

/// Whether what a person says is remembered. Off, nothing new is kept or extracted, and what's
/// remembered stays until it's forgotten.
public enum Remembering: String, Codable, Sendable, Equatable {
    case on
    case off
}

/// One atomic extraction result: how far into a conversation it read, and what that changed in
/// their memory. Lifecycle events such as `cleared` cannot be nested.
public struct MemoryExtractionCommit: Codable, Sendable, Equatable {
    public let generation: MemoryGeneration
    /// The conversation whose exchanges were read.
    public let conversation: ConversationID
    /// The last of them: what comes after it in the conversation is new.
    public let readThrough: MemorySourceID
    public let changes: [MemoryFactEvent]

    public init(
        generation: MemoryGeneration,
        conversation: ConversationID,
        readThrough: MemorySourceID,
        changes: [MemoryFactEvent]
    ) {
        self.generation = generation
        self.conversation = conversation
        self.readThrough = readThrough
        self.changes = changes
    }
}

/// What reading their messages changed in their memory.
public enum MemoryFactEvent: Codable, Sendable, Equatable {
    /// A conversation showed something new about them.
    case learned(MemoryFact)
    /// What they said made a fact untrue.
    case ended(MemoryFactID, Said)
}
