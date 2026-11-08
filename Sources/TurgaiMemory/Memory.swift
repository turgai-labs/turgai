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

/// How the person is related to whom or what a fact names.
public enum MemoryRelation: String, Codable, Sendable, CaseIterable {
    case name
    case livesIn
    case from
    case worksAt
    case worksAs
    case studies
    case speaks
    case likes
    case dislikes
    case owns
    case partner
    case child
    case parent
    case sibling
    case friend
    case colleague
    case plans

    /// How many a person has at once.
    public enum AtOnce: Sendable {
        /// A new one ends the one before.
        case one
        case many
    }

    public var atOnce: AtOnce {
        switch self {
        case .name, .livesIn, .from, .worksAt, .worksAs, .partner: .one
        case .studies, .speaks, .likes, .dislikes, .owns, .child, .parent, .sibling, .friend, .colleague, .plans:
            .many
        }
    }

    /// It as the person reads it: `Lives in`.
    public var words: String {
        switch self {
        case .name: "Name"
        case .livesIn: "Lives in"
        case .from: "From"
        case .worksAt: "Works at"
        case .worksAs: "Works as"
        case .studies: "Studies"
        case .speaks: "Speaks"
        case .likes: "Likes"
        case .dislikes: "Dislikes"
        case .owns: "Owns"
        case .partner: "Partner"
        case .child: "Child"
        case .parent: "Parent"
        case .sibling: "Sibling"
        case .friend: "Friend"
        case .colleague: "Colleague"
        case .plans: "Plans"
        }
    }
}

/// Who or what a fact names, as it was written, its spaces collapsed: `Haar` or `Ann`.
public struct MemoryName: Hashable, Codable, Sendable, CustomStringConvertible {
    /// How long a name is, at most.
    public static let maximumLength = 100

    public let rawValue: String

    /// `written`, as a name: `nil` when nothing's written, or too much.
    public init?(_ written: String) {
        let name = written.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty, name.count <= Self.maximumLength else { return nil }
        self.rawValue = name
    }

    /// Whether it names what `other` names, its case aside.
    public func isSame(as other: MemoryName) -> Bool {
        rawValue.lowercased() == other.rawValue.lowercased()
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

/// Something a conversation showed about the person: how they're related to whom or what, with
/// the exchange it came from. It's current until what they say makes it untrue, or they have it
/// forgotten.
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
    public let relation: MemoryRelation
    public let to: MemoryName
    /// Where they said it.
    public let learned: Said
    public private(set) var status: Status

    /// A fact just learned: current.
    public init(id: MemoryFactID = MemoryFactID(), relation: MemoryRelation, to: MemoryName, learned: Said) {
        self.id = id
        self.relation = relation
        self.to = to
        self.learned = learned
        self.status = .current
    }

    /// It as a line of their memory: `Lives in: Haar`.
    public var line: String {
        "\(relation.words): \(to)"
    }

    /// Whether it says what `other` says: the same relation, to the same name.
    public func isSame(as other: MemoryFact) -> Bool {
        relation == other.relation && to.isSame(as: other.to)
    }

    mutating func transition(to status: Status) {
        self.status = status
    }
}

/// What one memory extraction reads: what's remembered, which the extractor numbers from 1; and one
/// conversation's exchanges, the last few read already, as context, and those since, numbered from 1.
public struct ExtractionInput: Codable, Sendable, Equatable {
    /// The conversation they're from.
    public let conversation: ConversationID
    /// Its last exchanges read already: context only.
    public let earlier: [MemoryObservation]
    /// Its exchanges since: what's read now.
    public let new: [MemoryObservation]
    public let generation: MemoryGeneration
    /// What's remembered: the facts current when it was taken.
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

    /// The fact remembered numbered `number`, counting from 1: none when there's no such one.
    public func fact(_ number: Int) -> MemoryFact? {
        existingFacts.indices.contains(number - 1) ? existingFacts[number - 1] : nil
    }
}
