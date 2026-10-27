import DiscoverableActors
import DistributedCluster
import Foundation

// The doc comment below is the description models and the objects window show.
// The root checks in with the directory. Lists and reminders are reached by
// walking from it, and the root keeps them alive: a distributed actor lives
// only while something holds it, and a caller gets only references.

/// The user's reminders, as lists of reminders.
@Discoverable
public distributed actor Reminders {
    public typealias ActorSystem = ClusterSystem

    private let client: RemindersClient
    private var known: [ReminderListID: ReminderList] = [:]

    public init(actorSystem: ActorSystem, client: RemindersClient) async throws {
        self.actorSystem = actorSystem
        self.client = client
        let id = self.id
        let object = try DiscoverableObject.resolve(id: id, using: actorSystem)
        await actorSystem.receptionist.checkIn(object, with: .objects)
    }

    /// The reminder lists, such as "Groceries" or "Work".
    @DiscoverableAction(safe: true, idempotent: true)
    public distributed func lists() async throws -> [ReminderList] {
        var lists: [ReminderList] = []
        for record in try await client.lists() {
            if let list = known[record.id] {
                try await list.refresh(record)
                lists.append(list)
            } else {
                let list = ReminderList(actorSystem: actorSystem, client: client, record: record)
                known[record.id] = list
                lists.append(list)
            }
        }
        return lists
    }

    /// Add a reminder, to the default list unless another is named.
    /// - Parameters:
    ///   - title: What to be reminded of.
    ///   - notes: More detail, if any.
    ///   - due: When it's due, if it has a due date.
    ///   - list: The list's name, such as "Groceries"; the default list if omitted.
    public distributed func add(
        title: String, notes: String? = nil, due: Date? = nil, list: String? = nil
    ) async throws -> Reminder {
        let target: ReminderListID
        if let list {
            let records = try await client.lists()
            guard let match = records.first(where: { $0.title.caseInsensitiveCompare(list) == .orderedSame }) else {
                throw ReminderError.unknownListName(list, available: records.map(\.title))
            }
            target = match.id
        } else {
            target = try await client.defaultList().id
        }
        _ = try await lists()
        guard let reminderList = known[target] else { throw ReminderError.unknownList(target) }
        return try await reminderList.add(title: title, notes: notes, due: due)
    }
}

/// A list of reminders, such as "Groceries".
@Discoverable
public distributed actor ReminderList {
    public typealias ActorSystem = ClusterSystem

    private let client: RemindersClient
    private var record: ReminderListRecord
    private var known: [ReminderID: Reminder] = [:]

    init(actorSystem: ActorSystem, client: RemindersClient, record: ReminderListRecord) {
        self.actorSystem = actorSystem
        self.client = client
        self.record = record
    }

    /// The list's name.
    public distributed var title: String { record.title }

    /// The reminders in this list.
    /// - Parameter includeCompleted: Whether to include completed reminders too.
    @DiscoverableAction(safe: true, idempotent: true)
    public distributed func reminders(includeCompleted: Bool = false) async throws -> [Reminder] {
        var reminders: [Reminder] = []
        for record in try await client.reminders(record.id, includeCompleted) {
            reminders.append(try await reminder(for: record))
        }
        return reminders
    }

    /// Add a reminder to this list.
    /// - Parameters:
    ///   - title: What to be reminded of.
    ///   - notes: More detail, if any.
    ///   - due: When it's due, if it has a due date.
    public distributed func add(title: String, notes: String? = nil, due: Date? = nil) async throws -> Reminder {
        try await reminder(for: try await client.add(title, notes, due, record.id))
    }

    distributed func refresh(_ record: ReminderListRecord) {
        self.record = record
    }

    private func reminder(for record: ReminderRecord) async throws -> Reminder {
        if let reminder = known[record.id] {
            try await reminder.refresh(record)
            return reminder
        }
        let reminder = Reminder(actorSystem: actorSystem, client: client, record: record)
        known[record.id] = reminder
        return reminder
    }
}

/// One reminder. Its properties are as of when it was last listed or changed.
@Discoverable
public distributed actor Reminder {
    public typealias ActorSystem = ClusterSystem

    private let client: RemindersClient
    private var record: ReminderRecord

    init(actorSystem: ActorSystem, client: RemindersClient, record: ReminderRecord) {
        self.actorSystem = actorSystem
        self.client = client
        self.record = record
    }

    /// What to be reminded of.
    public distributed var title: String { record.title }

    /// More detail, if any.
    public distributed var notes: String? { record.notes }

    /// When it's due, if it has a due date.
    public distributed var due: Date? { record.due }

    /// Whether it's done.
    public distributed var isCompleted: Bool { record.isCompleted }

    /// Mark the reminder as done.
    @DiscoverableAction(idempotent: true, when: "!record.isCompleted")
    public distributed func complete() async throws {
        record = try await client.setCompleted(record.id, true)
    }

    /// Mark a done reminder as not done again.
    @DiscoverableAction(idempotent: true, when: "record.isCompleted")
    public distributed func reopen() async throws {
        record = try await client.setCompleted(record.id, false)
    }

    distributed func refresh(_ record: ReminderRecord) {
        self.record = record
    }

    /// Change when the reminder is due.
    /// - Parameter due: The new due date, or null to remove it.
    @DiscoverableAction(idempotent: true)
    public distributed func reschedule(to due: Date?) async throws {
        record = try await client.reschedule(record.id, due)
    }
}

// MARK: - Store

/// Reminders as a value of closures, in the same style as `TelegramAPIClient`:
/// compose the live client at the boundary with ``live``, inject a stub in tests.
public struct RemindersClient: Sendable {
    public var lists: @Sendable () async throws -> [ReminderListRecord]
    /// Where new reminders go when no list is named.
    public var defaultList: @Sendable () async throws -> ReminderListRecord
    public var reminders: @Sendable (_ list: ReminderListID, _ includeCompleted: Bool) async throws -> [ReminderRecord]
    public var add:
        @Sendable (_ title: String, _ notes: String?, _ due: Date?, _ list: ReminderListID) async throws ->
            ReminderRecord
    public var setCompleted: @Sendable (_ id: ReminderID, _ isCompleted: Bool) async throws -> ReminderRecord
    public var reschedule: @Sendable (_ id: ReminderID, _ due: Date?) async throws -> ReminderRecord

    public init(
        lists: @escaping @Sendable () async throws -> [ReminderListRecord],
        defaultList: @escaping @Sendable () async throws -> ReminderListRecord,
        reminders:
            @escaping @Sendable (_ list: ReminderListID, _ includeCompleted: Bool) async throws ->
            [ReminderRecord],
        add:
            @escaping @Sendable (_ title: String, _ notes: String?, _ due: Date?, _ list: ReminderListID)
            async throws -> ReminderRecord,
        setCompleted: @escaping @Sendable (_ id: ReminderID, _ isCompleted: Bool) async throws -> ReminderRecord,
        reschedule: @escaping @Sendable (_ id: ReminderID, _ due: Date?) async throws -> ReminderRecord
    ) {
        self.lists = lists
        self.defaultList = defaultList
        self.reminders = reminders
        self.add = add
        self.setCompleted = setCompleted
        self.reschedule = reschedule
    }
}

public struct ReminderListID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ReminderID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ReminderListRecord: Codable, Sendable, Equatable {
    public var id: ReminderListID
    public var title: String

    public init(id: ReminderListID, title: String) {
        self.id = id
        self.title = title
    }
}

public struct ReminderRecord: Codable, Sendable, Equatable {
    public var id: ReminderID
    public var list: ReminderListID
    public var title: String
    public var notes: String?
    public var due: Date?
    public var isCompleted: Bool

    public init(
        id: ReminderID,
        list: ReminderListID,
        title: String,
        notes: String? = nil,
        due: Date? = nil,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.list = list
        self.title = title
        self.notes = notes
        self.due = due
        self.isCompleted = isCompleted
    }
}

/// Codable, so the cluster can return it to a caller on another node.
public enum ReminderError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case accessDenied
    case unknownList(ReminderListID)
    case unknownListName(String, available: [String])
    case noDefaultList
    case unknownReminder(ReminderID)

    public var description: String {
        switch self {
        case .accessDenied:
            "Turgai isn't allowed to use Reminders. Allow it in System Settings › Privacy & Security › Reminders."
        case .unknownList(let id): "There's no reminder list \(id.rawValue) any more."
        case .unknownListName(let name, let available):
            "There's no reminder list named \(name); the lists are \(available.joined(separator: ", "))."
        case .noDefaultList: "Reminders has no default list; name one of the lists."
        case .unknownReminder(let id): "There's no reminder \(id.rawValue) any more."
        }
    }
}

/// Read by everyone and written by no one, until whoever runs its node is known.
extension Reminders: AccessControlled {
    public func access(for chain: CallChain) -> ObjectAccess { .readByEveryone }
}

/// Read by everyone and written by no one, until whoever runs its node is known.
extension ReminderList: AccessControlled {
    public func access(for chain: CallChain) -> ObjectAccess { .readByEveryone }
}

/// Read by everyone and written by no one, until whoever runs its node is known.
extension Reminder: AccessControlled {
    public func access(for chain: CallChain) -> ObjectAccess { .readByEveryone }
}
