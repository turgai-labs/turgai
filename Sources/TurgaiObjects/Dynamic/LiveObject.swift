import DiscoverableActors
import Foundation
import TurgaiDomain

// A dynamic object's domain, with no actor in it: what happens to an object (its events), what it
// is (its state, a reducer over the events), and what may happen next (decisions, from its state).
// ``DynamicObject`` runs its code and journals the events these decide.

/// What happened to a dynamic object, as journaled: its code, what it holds, and what it did.
public enum DynamicObjectEvent: Codable, Sendable {
    /// The code of its type it runs from now on, first or new, with the starting values of the
    /// data new to it.
    case adopted(BehaviorID, Script, starts: [String: JSONValue], by: CallScope)
    /// `audience` given `level` of access, or none at all.
    case shared(with: Audience, AccessLevel?)
    /// What it's called and what it was made for, as it was asked for: an object made by name has
    /// them, one made by code doesn't.
    case described(name: String, description: String?)
    /// A message, or a task its code started, handled: the fields it changed.
    case handled(Origin, changes: [String: JSONValue])
    /// A message, or a task its code started, that failed, and why. It changes no field: the
    /// object is as it was before it.
    case failed(Origin, problem: String)
    /// Values set on it directly, with no message.
    case set([String: JSONValue])
    /// An event it announced, to every object subscribed to it.
    case announced(Announcement)
    case removed
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

// MARK: State

/// A dynamic object's journaled state: living, or removed.
public enum DynamicObjectState: Codable, Sendable {
    /// Living: its code and what it holds, from its own events.
    case live(LiveObject)
    /// Removed for good: what it was, kept with its history.
    case removed(LiveObject)

    /// An object with no events yet: no code, and nothing held.
    public static let new = DynamicObjectState.live(LiveObject())

    /// The state after `event`. An event the state can't follow from never reaches it, since
    /// every event is decided from the state it follows; it leaves the state as it is.
    public func applying(_ event: DynamicObjectEvent) -> DynamicObjectState {
        switch (self, event) {
        case (.live(let object), .removed): .removed(object)
        case (.live(let object), _): .live(object.applying(event))
        case (.removed, _): self
        }
    }

    /// The object, when it's living.
    public var live: LiveObject {
        get throws(DynamicObjectError) {
            switch self {
            case .live(let object): object
            case .removed: throw .removed
            }
        }
    }

    // MARK: Decisions

    /// Its removal, which only a living object takes.
    func removing() throws(DynamicObjectError) -> DynamicObjectEvent {
        _ = try live
        return .removed
    }
}

/// A living object: its code, what it's called when it has a name, the values it holds of its
/// own, and how its code is doing.
public struct LiveObject: Codable, Sendable {
    /// The type it runs, and its code as it runs it: none until it's given one.
    public private(set) var type: BehaviorID?
    public private(set) var code: Script?
    /// Whoever it was made by: on whose behalf it was first given code. What it starts itself, its
    /// tasks and the events it follows, is on their behalf.
    public private(set) var maker: CallScope?
    /// Who may read it and who may write it: its maker's alone, from when it's made, until shared.
    public private(set) var access: ObjectAccess?
    /// What it's called and what it was made for: an object made by name has them.
    public private(set) var name: String?
    public private(set) var description: String?
    /// The values it holds: its own, never read from its code, as an Erlang process's state is
    /// its own once it's spawned.
    public private(set) var fields: [String: JSONValue] = [:]
    public private(set) var health = Health.working
    /// What happened to it lately, newest first.
    public private(set) var recent: [Happening] = []

    /// How many happenings `recent` keeps.
    static let recentLimit = 10

    init() {}

    /// The object after `event`, which keeps living.
    func applying(_ event: DynamicObjectEvent) -> LiveObject {
        var next = self
        switch event {
        case .adopted(let type, let code, let starts, let scope):
            next.type = type
            next.code = code
            next.maker = maker ?? scope
            next.access = access ?? ObjectAccess(madeBy: scope)
            // New code starts again: what failed before is the old code's.
            next.health = .working
            // Data new to it starts as its code has it; the values it holds stay its own, and
            // data its code no longer has is gone.
            next.fields = starts.merging(fields.filter { starts[$0.key] != nil }) { _, held in held }
        case .shared(let audience, let level):
            next.access = access?.sharing(with: audience, level)
        case .described(let name, let description):
            next.name = name
            next.description = description
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
        case .removed:
            break
        }
        return next
    }

    private func remembering(_ happening: Happening) -> [Happening] {
        Array(([happening] + recent).prefix(Self.recentLimit))
    }

    // MARK: Decisions

    /// Its code, which it runs once it's given one.
    var running: Script {
        get throws(DynamicObjectError) {
            guard let code else { throw .noCode }
            return code
        }
    }

    /// Running `code` of the type `type` from now on, with `starts` for data new to it, given on
    /// behalf of `scope`.
    func adopting(
        _ type: BehaviorID, _ code: Script, starts: [String: JSONValue], by scope: CallScope
    ) -> DynamicObjectEvent {
        .adopted(type, code, starts: starts, by: scope)
    }

    /// On whose behalf what it starts itself runs: whoever made it, once it has code.
    var startedBy: CallScope {
        get throws(DynamicObjectError) {
            guard let maker else { throw .noCode }
            return maker
        }
    }

    /// Its name and what it was made for, which an object is given once.
    func describing(name: String, description: String?) throws(DynamicObjectError) -> DynamicObjectEvent {
        guard self.name == nil else { throw .alreadyCreated }
        return .described(name: name, description: description)
    }

    /// `audience` given `level` of access, or none, by a call on behalf of `scope`: only one that
    /// may write it shares it.
    func sharing(with audience: Audience, _ level: AccessLevel?, by scope: CallScope) throws(DynamicObjectError)
        -> DynamicObjectEvent
    {
        guard let access else { throw .noCode }
        guard access.allows(scope, .write) else { throw .notAllowed(.write) }
        return .shared(with: audience, level)
    }

    /// Whether it takes `message` in the state it's in: one its state doesn't take is refused, as
    /// gen_statem drops an event no state handles.
    func taking(_ message: String) throws(DynamicObjectError) {
        if case .string(let current)? = fields["state"]?.objectValue?["$case"],
            !(try running).takes(message, in: current)
        {
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

    /// Setting `values` of its data directly: each must be data its code holds.
    func setting(_ values: [String: JSONValue]) throws -> DynamicObjectEvent {
        let held = try ObjectShape(try running).fields.map(\.name)
        if let unknown = values.keys.sorted().first(where: { !held.contains($0) }) {
            throw DynamicObjectError.unknownField(unknown, held: held)
        }
        return .set(values)
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
    case alreadyCreated
    case noCode
    case removed
    case notTakenNow(String, state: String)
    case unknownField(String, held: [String])
    case noReference(String)
    case noObjectNamed(String)
    case severalNamed(String)
    /// A call made through a type this object isn't.
    case notA(String, isA: String)
    /// A call whose scope isn't allowed to go as far as it asked.
    case notAllowed(AccessLevel)

    public var description: String {
        switch self {
        case .alreadyCreated: "This object is already described."
        case .noCode: "This object has no code yet."
        case .removed: "This object was removed."
        case .notTakenNow(let message, let state): "It's \(state): it doesn't take `\(message)` now."
        case .unknownField(let name, let held):
            "It holds no `\(name)`. It holds \(held.map { "`\($0)`" }.joined(separator: ", "))."
        case .noReference(let value): "\(value) isn't an object to call."
        case .noObjectNamed(let name): "There's no object named `\(name)`."
        case .notAllowed(.read): "Not allowed to read this object."
        case .notAllowed(.write): "Not allowed to write this object."
        case .severalNamed(let name): "Several objects are named `\(name)`."
        case .notA(let type, let isA): "It's a `\(isA)`, not a `\(type)`."
        }
    }
}
