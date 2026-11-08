import TurgaiDomain

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

/// One exchange the person had: what they said in a conversation, and what its agent answered.
/// The subject is implicit: each observation lives in exactly one user's journal.
public struct MemoryObservation: Hashable, Codable, Sendable {
    public let id: ObservationID
    public let sourceID: MemorySourceID
    /// The conversation it was in: it's read with the rest of that conversation.
    public let conversation: ConversationID
    /// The agent that answered, whose model reads it.
    public let heardBy: AgentProfileID
    /// Its message's id in the channel it came through: where it's marked once something's noted.
    public let channelMessageID: ChannelMessageID?
    public let text: String
    public let response: String?
    public let observedAt: Date

    public init(
        id: ObservationID = ObservationID(),
        sourceID: MemorySourceID,
        conversation: ConversationID,
        heardBy: AgentProfileID,
        channelMessageID: ChannelMessageID? = nil,
        text: String,
        response: String? = nil,
        observedAt: Date
    ) {
        self.id = id
        self.sourceID = sourceID
        self.conversation = conversation
        self.heardBy = heardBy
        self.channelMessageID = channelMessageID
        self.text = text
        self.response = response
        self.observedAt = observedAt
    }
}

/// A name in a person's memory, as it's compared: trimmed, lowercased, its spaces collapsed, so
/// `Lives in` and `lives  in` are the same name.
public struct MemoryName: Hashable, Codable, Sendable, CustomStringConvertible {
    /// How long a name is, at most.
    public static let maximumLength = 100

    public let rawValue: String

    /// `written`, as a name: `nil` when nothing's written, or too much.
    public init?(_ written: String) {
        let name = written.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty, name.count <= Self.maximumLength else { return nil }
        self.rawValue = name
    }

    public var description: String { rawValue }
}

/// Where a fact is in a person's memory: the names from them down, `lives in` or
/// `family › sister`. Several facts can be at one path.
public struct MemoryPath: Hashable, Codable, Sendable, CustomStringConvertible {
    /// How deep a path goes, at most.
    public static let maximumDepth = 3

    public let names: [MemoryName]

    /// `written`, from the person down, as a path: `nil` when a name isn't one, or there are none
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

/// What a fact says, as it was written, its ends trimmed.
public struct MemoryValue: Hashable, Codable, Sendable, CustomStringConvertible {
    /// How long a value is, at most.
    public static let maximumLength = 500

    public let rawValue: String

    /// `written`, as a value: `nil` when nothing's written, or too much.
    public init?(_ written: String) {
        let value = written.trimmed()
        guard !value.isEmpty, value.count <= Self.maximumLength else { return nil }
        self.rawValue = value
    }

    /// Whether it says what `other` says, its case and spaces aside.
    public func isSame(as other: MemoryValue) -> Bool {
        compared == other.compared
    }

    private var compared: String {
        rawValue.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public var description: String { rawValue }
}

/// Where the person said something: the message, and when.
public struct Said: Hashable, Codable, Sendable {
    public let observation: ObservationID
    public let at: Date

    public init(observation: ObservationID, at: Date) {
        self.observation = observation
        self.at = at
    }
}

/// Something a conversation showed about the person, at its place in their memory, with the exchange
/// it came from. It's current until what they say makes it untrue, or they have it forgotten.
public struct MemoryFact: Hashable, Codable, Sendable {
    public enum Status: Hashable, Codable, Sendable {
        /// True, as far as they've said.
        case current
        /// What they said made it untrue.
        case ended(Said)
        /// They had it forgotten.
        case forgotten
    }

    public let id: MemoryFactID
    public let path: MemoryPath
    public let value: MemoryValue
    /// Where they said it.
    public let learned: Said
    public let confidence: Double
    public private(set) var status: Status

    /// A fact just learned: current.
    public init(
        id: MemoryFactID = MemoryFactID(),
        path: MemoryPath,
        value: MemoryValue,
        learned: Said,
        confidence: Double
    ) {
        self.id = id
        self.path = path
        self.value = value
        self.learned = learned
        self.confidence = min(max(confidence, 0), 1)
        self.status = .current
    }

    /// It as a line of their memory: `lives in: Haar`.
    public var line: String {
        "\(path): \(value)"
    }

    mutating func transition(to status: Status) {
        self.status = status
    }
}

/// What one memory extraction reads: one conversation's exchanges, the last few read already, as
/// context, and those since, which the extractor numbers from 1.
public struct ExtractionInput: Codable, Sendable, Equatable {
    /// The conversation they're from.
    public let conversation: ConversationID
    /// Its last exchanges read already: context only.
    public let earlier: [MemoryObservation]
    /// Its exchanges since: what's read now.
    public let new: [MemoryObservation]
    public let generation: MemoryGeneration
    public let existingFacts: [MemoryFact]

    public init(
        conversation: ConversationID,
        earlier: [MemoryObservation] = [],
        new: [MemoryObservation],
        generation: MemoryGeneration,
        existingFacts: [MemoryFact]
    ) {
        self.conversation = conversation
        self.earlier = earlier
        self.new = new
        self.generation = generation
        self.existingFacts = existingFacts
    }

    /// The new exchange numbered `number`, counting from 1: none when there's no such one.
    public func exchange(_ number: Int) -> MemoryObservation? {
        new.indices.contains(number - 1) ? new[number - 1] : nil
    }
}
