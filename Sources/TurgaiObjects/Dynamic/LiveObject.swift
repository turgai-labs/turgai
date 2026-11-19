import DiscoverableActors
import Foundation
import TurgaiCalls
import TurgaiDomain

// A dynamic object's domain, with no actor in it: what happens to an object (its events), what it
// is (its state, a reducer over the events), and what may happen next (decisions, from its state).
// ``DynamicObject`` runs its code and journals the events these decide.

/// What happened to a dynamic object, as journaled: its code, what it holds, and what it did.
public enum DynamicObjectEvent: Codable, Sendable {
    /// The code of its type it runs from now on, first or new, with the starting values of the
    /// data new to it, given on behalf of `by`. One that another object's code made is held by it.
    case adopted(BehaviorID, Script, starts: [String: JSONValue], by: CallScope, in: ConversationID?, heldBy: ObjectID?)
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

/// A dynamic object's state: not made yet, living, or removed.
public enum DynamicObjectState: Codable, Sendable {
    /// Not made yet: no code, and no maker. Whoever gives it code makes it.
    case unmade
    /// Living: its code, its maker, who may use it, and what it holds.
    case live(LiveObject)
    /// Removed: what it was, kept with its history. Its name is free, and an object made by it
    /// again is a new life of it, as a name reaches whichever object is there now.
    case removed(LiveObject)

    /// The state after `event`. An event the state can't follow from never reaches it, since
    /// every event is decided from the state it follows; it leaves the state as it is.
    public func applying(_ event: DynamicObjectEvent) -> DynamicObjectState {
        switch (self, event) {
        case (.unmade, .adopted(let type, let code, let starts, let maker, let place, let holder)),
            (.removed, .adopted(let type, let code, let starts, let maker, let place, let holder)):
            .live(LiveObject(type: type, code: code, fields: starts, maker: maker, madeIn: place, heldBy: holder))
        case (.unmade, _): self
        case (.live(let object), .removed): .removed(object)
        case (.live(let object), _): .live(object.applying(event))
        case (.removed, _): self
        }
    }

    /// The object, when it's living.
    public var live: LiveObject {
        get throws(DynamicObjectError) {
            switch self {
            case .unmade: throw .noCode
            case .live(let object): object
            case .removed: throw .removed
            }
        }
    }

    /// Who may read it and who may write it, for a call through `chain`: an object not made yet,
    /// or removed, is the caller's to make.
    func access(for chain: CallChain) -> Access {
        switch self {
        case .unmade, .removed: Access(madeBy: chain.scope)
        case .live(let object): object.access
        }
    }

    // MARK: Decisions

    /// Running `code` of the type `type` from now on, with `starts` for the data new to it, given
    /// by a call through `chain`: an object not made yet becomes the caller's, and the object's
    /// whose code made it, if one did, which alone may use it; a living one takes it from a call
    /// that may write it.
    func adopting(_ type: BehaviorID, _ code: Script, starts: [String: JSONValue], by chain: CallChain) throws
        -> DynamicObjectEvent
    {
        switch self {
        // Not made yet, or removed: a new life, its maker's.
        case .unmade, .removed:
            let holder = chain.actors.last.map(ObjectID.init).flatMap {
                DynamicObject.identity(of: $0) == nil ? nil : $0
            }
            return .adopted(type, code, starts: starts, by: chain.scope, in: chain.place, heldBy: holder)
        case .live(let object):
            try object.changeable(by: chain)
            return .adopted(type, code, starts: starts, by: chain.scope, in: chain.place, heldBy: nil)
        }
    }

    /// The values it holds now, which new code keeps: none for an object not made yet.
    var held: [String: JSONValue] {
        get throws(DynamicObjectError) {
            switch self {
            case .unmade, .removed: [:]
            case .live(let object): object.fields
            }
        }
    }

    /// Its removal by a call through `chain`, which only a living object takes, from a call that may
    /// write it.
    func removing(by chain: CallChain) throws -> DynamicObjectEvent {
        try live.changeable(by: chain)
        return .removed
    }
}

/// A living object: its code, whoever made it and who may use it, what it's called when it has a
/// name, the values it holds of its own, and how its code is doing.
public struct LiveObject: Codable, Sendable {
    /// The type it runs, and its code as it runs it.
    public private(set) var type: BehaviorID
    public private(set) var code: Script
    /// Whoever it was made by: on whose behalf it was first given code. What it starts itself, its
    /// tasks and the events it follows, is on their behalf.
    public let maker: CallScope
    /// The conversation it was made in, when it was made in one: where what it says goes.
    public let madeIn: ConversationID?
    /// Who may read it and who may write it: its maker's alone, from when it's made, until shared.
    public private(set) var access: Access
    /// What it's called and what it was made for: an object made by name has them.
    public private(set) var name: String?
    public private(set) var description: String?
    /// The values it holds: its own, never read from its code, as an Erlang process's state is
    /// its own once it's spawned.
    public private(set) var fields: [String: JSONValue]
    public private(set) var health = Health.working
    /// What happened to it lately, newest first.
    public private(set) var recent: [Happening] = []

    /// How many happenings `recent` keeps.
    static let recentLimit = 10

    /// An object just made on behalf of `maker`, running `code` of the type `type`, holding
    /// `fields`: its maker's, or, made by another object's code, its holder's alone.
    init(
        type: BehaviorID, code: Script, fields: [String: JSONValue], maker: CallScope, madeIn: ConversationID?,
        heldBy holder: ObjectID?
    ) {
        self.type = type
        self.code = code
        self.fields = fields
        self.maker = maker
        self.madeIn = madeIn
        self.access = holder.map { Access(heldBy: $0.callActor) } ?? Access(madeBy: maker)
    }

    /// The object after `event`, which keeps living.
    func applying(_ event: DynamicObjectEvent) -> LiveObject {
        var next = self
        switch event {
        case .adopted(let type, let code, let starts, _, _, _):
            next.type = type
            next.code = code
            // New code starts again: what failed before is the old code's.
            next.health = .working
            // Data new to it starts as its code has it; the values it holds stay its own, and
            // data its code no longer has is gone.
            next.fields = starts.merging(fields.filter { starts[$0.key] != nil }) { _, held in held }
        case .shared(let audience, let level):
            next.access = access.sharing(with: audience, level)
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

    /// Refuses a change by a call through `chain` that may not write it.
    func changeable(by chain: CallChain) throws {
        guard access.allows(chain, .write) else { throw NotAllowed(.write) }
    }

    /// Its name and what it was made for, which an object is given once, by a call through `chain`
    /// that may write it.
    func describing(name: String, description: String?, by chain: CallChain) throws -> DynamicObjectEvent {
        try changeable(by: chain)
        guard self.name == nil else { throw DynamicObjectError.alreadyCreated }
        return .described(name: name, description: description)
    }

    /// `audience` given `level` of access, or none, by a call through `chain`: only one that may
    /// write it shares it.
    func sharing(with audience: Audience, _ level: AccessLevel?, by chain: CallChain) throws -> DynamicObjectEvent {
        try changeable(by: chain)
        return .shared(with: audience, level)
    }

    /// Whether it takes `message` in the state it's in: one its state doesn't take is refused, as
    /// gen_statem drops an event no state handles.
    func taking(_ message: String) throws(DynamicObjectError) {
        if case .string(let current)? = fields["state"]?.objectValue?["$case"],
            !code.takes(message, in: current)
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

    /// Setting `values` of its data directly, by a call through `chain` that may write it: each must
    /// be data its code holds.
    func setting(_ values: [String: JSONValue], by chain: CallChain) throws -> DynamicObjectEvent {
        try changeable(by: chain)
        let held = try ObjectShape(code).fields.map(\.name)
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
        case .severalNamed(let name): "Several objects are named `\(name)`."
        case .notA(let type, let isA): "It's a `\(isA)`, not a `\(type)`."
        }
    }
}
