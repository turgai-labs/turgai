#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// One of a space's tasks, as Tasks shows it: a chat's reminder, or an object's field, with what it
/// does and when it's due.
public struct TaskListing: Codable, Hashable, Sendable, Identifiable {
    /// When it's due: again and again, as a schedule says, or once, at a date.
    public enum When: Codable, Hashable, Sendable {
        case repeating(String)
        case once(Date)
    }

    /// A chat, as the server names it: one of the space's, in whichever channel it's in.
    public struct Chat: Codable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    /// The durable schedule's or timer's id: the same for as long as it's kept.
    public struct ID: Codable, Hashable, Sendable, RawRepresentable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(from decoder: Decoder) throws {
            self.rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Whose it is, which says what can be done to it: a chat's schedule, by its name there, is
    /// paused, resumed or cancelled; a chat's reminder, by its name there, is cancelled; an object's
    /// code changes its own.
    public enum Kind: Codable, Hashable, Sendable {
        case schedule(in: Chat, named: String)
        case reminder(in: Chat, named: String)
        case object
    }

    public let id: ID
    /// What it's for: a chat's task, by its name there, or an object's field, `ticker · tick`.
    public let title: String
    /// What it does when it's due, for a chat's task: `asks for the news`.
    public let does: String?
    public let when: When
    public let paused: Bool
    public let kind: Kind

    public init(id: ID, title: String, does: String?, when: When, paused: Bool, kind: Kind) {
        self.id = id
        self.title = title
        self.does = does
        self.when = when
        self.paused = paused
        self.kind = kind
    }
}

/// A change to a chat's schedule.
public enum ScheduleChange: String, Codable, Sendable {
    case pause, resume, cancel
}
