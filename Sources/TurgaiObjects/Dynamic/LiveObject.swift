import DiscoverableActors
import Foundation

// A dynamic object's domain, with no actor in it: what happens to an object (its events), what it
// is (its state, a reducer over the events), and what may happen next (decisions, from its state).
// ``DynamicObject`` runs its code and journals the events these decide.

/// What happened to a dynamic object, as journaled.
public enum DynamicObjectEvent: Codable, Sendable {
    case created(Birth)
    /// A message, or a task its code started, handled: the fields it changed.
    case handled(Origin, changes: [String: JSONValue])
    /// A message, or a task its code started, that failed, and why. It changes no field: the
    /// object is as it was before it.
    case failed(Origin, problem: String)
    /// Values set on it directly, with no message.
    case set([String: JSONValue])
    /// An event it announced, to every object subscribed to it.
    case announced(Announcement)
    /// A new version of the kind it shares, and the starting values of its data.
    case adopted(Script, starts: [String: JSONValue])
    case removed
}

/// What an object is made as: its name, what it was made for, the kind it runs and where, and
/// what it holds to start.
public struct Birth: Codable, Sendable {
    public let name: String
    /// What it was made for, in the words it was asked for with.
    public let description: String?
    public let kind: Script
    public let id: BehaviorID
    public let scope: ObjectScope
    public let start: [String: JSONValue]
    public let at: Date
}

/// An event an object announced: which, with its values.
public struct Announcement: Codable, Sendable, Equatable {
    public let event: String
    public let values: JSONValue

    public init(event: String, values: JSONValue) {
        self.event = event
        self.values = values
    }
}

/// What ran an object's code: a message it was sent, an event of an object it follows, held in
/// its field `from`, or a task its code started.
public enum Origin: Codable, Sendable, Equatable {
    case message(Delivery)
    case event(Delivery, from: String)
    case task(at: Date)
}

/// A message an object was sent: which, with what, and when.
public struct Delivery: Codable, Sendable, Equatable {
    public let message: String
    public let arguments: JSONValue
    public let at: Date
}

/// Whether an object's code is working: failing from the latest failure that nothing has cleared
/// since, which is the next handling of what failed, or new code.
public enum Health: Codable, Sendable, Equatable {
    case working
    case failing(Failure)
}

/// What failed, and why.
public struct Failure: Codable, Sendable, Equatable {
    public let origin: Origin
    public let problem: String
}

/// Something that happened to an object: a message or task handled, with what it changed, or one
/// that failed, with why.
public enum Happening: Codable, Sendable, Equatable {
    case handled(Origin, changes: [String: JSONValue])
    case failed(Origin, problem: String)
    case announced(Announcement)
}

/// The objects a call went through to get here, the first first: what makes calls that go round
/// in a circle fail, with the circle as the reason, instead of running until memory runs out.
public struct CallChain: Codable, Sendable, Equatable {
    public let objects: [String]

    /// How deep calls between objects may go.
    static let limit = 64

    /// A call from outside the objects: a model's, or another kind of object's.
    public static let start = CallChain(objects: [])

    /// The chain of a call `caller` makes, refused once it's too deep.
    func continuing(from caller: String) throws(DynamicObjectError) -> CallChain {
        let next = CallChain(objects: objects + [caller])
        guard next.objects.count <= Self.limit else { throw .callsTooDeep(next) }
        return next
    }

    /// The chain a message is handled in, on its own node: what its code's calls continue.
    @TaskLocal static var current = CallChain.start
}

// MARK: State

/// A dynamic object's journaled state: not made yet, living, or removed.
public enum DynamicObjectState: Codable, Sendable {
    /// An identity with nothing made behind it yet.
    case unmade
    case live(LiveObject)
    /// Removed for good: what it was, kept with its history.
    case removed(LiveObject)

    /// The state after `event`. An event the state can't follow from never reaches it, since
    /// every event is decided from the state it follows; it leaves the state as it is.
    public func applying(_ event: DynamicObjectEvent) -> DynamicObjectState {
        switch (self, event) {
        case (.unmade, .created(let birth)): .live(LiveObject(birth))
        case (.live(let object), .removed): .removed(object)
        case (.live(let object), _): .live(object.applying(event))
        case (.unmade, _), (.removed, _): self
        }
    }

    /// The object, when it's living.
    public var live: LiveObject {
        get throws(DynamicObjectError) {
            switch self {
            case .unmade: throw .notCreated
            case .live(let object): object
            case .removed: throw .removed
            }
        }
    }

    // MARK: Decisions

    /// Its making, which only an object not made yet takes.
    func creating(_ birth: Birth) throws(DynamicObjectError) -> DynamicObjectEvent {
        guard case .unmade = self else { throw .alreadyCreated }
        return .created(birth)
    }

    /// Its removal, which only a living object takes.
    func removing() throws(DynamicObjectError) -> DynamicObjectEvent {
        _ = try live
        return .removed
    }
}

/// A living object: what it was made as, the code it runs, the values it holds, and how its code
/// is doing.
public struct LiveObject: Codable, Sendable {
    public let name: String
    /// What it was made for, in the words it was asked for with.
    public let description: String?
    public let id: BehaviorID
    public let scope: ObjectScope
    public let createdAt: Date
    public private(set) var kind: Script
    /// The values it holds: its own, never read from its kind, as an Erlang process's state is
    /// its own once it's spawned.
    public private(set) var fields: [String: JSONValue]
    public private(set) var health: Health
    /// What happened to it lately, newest first.
    public private(set) var recent: [Happening]

    /// How many happenings `recent` keeps.
    static let recentLimit = 10

    init(_ birth: Birth) {
        name = birth.name
        description = birth.description
        id = birth.id
        scope = birth.scope
        createdAt = birth.at
        kind = birth.kind
        fields = birth.start
        health = .working
        recent = []
    }

    /// The object after `event`, which keeps living.
    func applying(_ event: DynamicObjectEvent) -> LiveObject {
        var next = self
        switch event {
        case .handled(let origin, let changes):
            next.fields.merge(changes) { _, changed in changed }
            if case .failing(let failure) = health, failure.origin.isAgain(origin) { next.health = .working }
            next.recent = remembering(.handled(origin, changes: changes))
        case .failed(let origin, let problem):
            next.health = .failing(Failure(origin: origin, problem: problem))
            next.recent = remembering(.failed(origin, problem: problem))
        case .set(let values):
            next.fields.merge(values) { _, set in set }
        case .announced(let announcement):
            next.recent = remembering(.announced(announcement))
        case .adopted(let kind, let starts):
            next.kind = kind
            // New code starts again: what failed before is the old code's.
            next.health = .working
            // Data new to it starts as its kind has it; the values it holds stay its own, and
            // data its kind no longer has is gone.
            next.fields = starts.merging(fields.filter { starts[$0.key] != nil }) { _, held in held }
        case .created, .removed:
            break
        }
        return next
    }

    private func remembering(_ happening: Happening) -> [Happening] {
        Array(([happening] + recent).prefix(Self.recentLimit))
    }

    // MARK: Decisions

    /// Whether it takes `message` in the state it's in: one its state doesn't take is refused, as
    /// gen_statem drops an event no state handles.
    func taking(_ message: String) throws(DynamicObjectError) {
        if case .string(let current)? = fields["state"]?.objectValue?["$case"], !kind.takes(message, in: current) {
            throw .notTakenNow(message, state: current)
        }
    }

    /// What handling `origin` comes to, once its code holds `after`: handled, when it changed a
    /// field or clears a failure of the same; nothing to journal otherwise.
    func handling(_ origin: Origin, holding after: [String: JSONValue]) -> DynamicObjectEvent? {
        let changes = after.filter { fields[$0.key] != $0.value }
        let clears = if case .failing(let failure) = health { failure.origin.isAgain(origin) } else { false }
        return changes.isEmpty && !clears ? nil : .handled(origin, changes: changes)
    }

    /// Setting `values` of its data directly: each must be data its kind holds.
    func setting(_ values: [String: JSONValue]) throws -> DynamicObjectEvent {
        let held = try ObjectShape(kind).fields.map(\.name)
        if let unknown = values.keys.sorted().first(where: { !held.contains($0) }) {
            throw DynamicObjectError.unknownField(unknown, held: held)
        }
        return .set(values)
    }

    /// The events its code announces: its `@Event` methods, by name.
    func announces() throws -> Set<String> {
        Set(try ObjectShape(kind).events.map(\.name))
    }

    /// Running `kind` from now on, with `starts` for data new to it.
    func adopting(_ kind: Script, starts: [String: JSONValue]) -> DynamicObjectEvent {
        .adopted(kind, starts: starts)
    }
}

extension Origin {
    /// Whether `other` runs the same thing again: the same message, the same event, or a task again.
    func isAgain(_ other: Origin) -> Bool {
        switch (self, other) {
        case (.message(let a), .message(let b)): a.message == b.message
        case (.event(let a, let from), .event(let b, let other)): a.message == b.message && from == other
        case (.task, .task): true
        default: false
        }
    }
}

public enum DynamicObjectError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case notCreated
    case alreadyCreated
    case removed
    case notTakenNow(String, state: String)
    case unknownField(String, held: [String])
    case noReference(String)
    case noObjectNamed(String)
    case callsTooDeep(CallChain)
    case notPublished(String)

    public var description: String {
        switch self {
        case .notCreated: "This object hasn't been created yet."
        case .alreadyCreated: "This object already exists."
        case .removed: "This object was removed."
        case .notTakenNow(let message, let state): "It's \(state): it doesn't take `\(message)` now."
        case .unknownField(let name, let held):
            "It holds no `\(name)`. It holds \(held.map { "`\($0)`" }.joined(separator: ", "))."
        case .noReference(let value): "\(value) isn't an object to call."
        case .noObjectNamed(let name): "There's no object named `\(name)`."
        case .notPublished(let name): "`\(name)` isn't published: an object made here answers through its functions."
        case .callsTooDeep(let chain):
            "calls between objects went \(chain.objects.count) deep: "
                + (chain.objects.prefix(6) + (chain.objects.count > 6 ? ["…"] : [])).joined(separator: " → ")
        }
    }
}
