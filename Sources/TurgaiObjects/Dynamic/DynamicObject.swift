import DiscoverableActors
import Distributed
import DistributedCluster
import EventSourcing
import Foundation
import TurgaiDomain
import VirtualActors

/// An object that runs Swift a model wrote, its ``Script``, the way an Erlang process runs a
/// module: a name, the code it runs, and its own fields. Its code runs as a live instance of its
/// actor, on this actor: it handles one message at a time, and messages interleave only where one
/// waits on another object, as Swift actors do. To other objects and to models, it's an object
/// like any other: each message its code takes is one of its actions.
///
/// It's a virtual actor keyed by its ``ObjectIdentity``: whoever has a reference to it can always
/// reach it, and it starts on demand, on any node. Its code and what it holds are its own,
/// journaled, so it comes back after a restart as it was: a restart only restores, and makes
/// nothing. The objects it holds are its own too: a new version of a type's code reaches them
/// through it, as down a tree.
@EventSourced
@VirtualActor
public distributed actor DynamicObject: DiscoverableActor {
    public typealias ActorSystem = ClusterSystem
    public typealias Dependency = ObjectNature
    public typealias Event = DynamicObjectEvent
    public typealias State = DynamicObjectState

    public var state = DynamicObjectState.new
    private let nature: ObjectNature
    /// Its code: stopped, or running as an instance started from what's journaled. It stops when
    /// its code changes or a message fails, as an Erlang process restarts from its last state.
    private var process = Process.stopped(generation: 0)
    /// Its subscribers, to the events the code it runs announces: replaced with each new code, so
    /// subscribers find theirs ended, and subscribe again.
    private var hub = _DiscoveryEventHub(events: [])
    /// The objects it follows, by the `@Subscribed` field holding each.
    private var followers: [String: Follower] = [:]

    /// An object followed: the one the field held, and the task delivering its events.
    private struct Follower: Sendable {
        let source: ObjectReference
        let task: Task<Void, Never>
    }

    /// An object's code, as it runs on this actor. Each start is a generation: a task belongs to
    /// the instance that started it, and is gone with it.
    private enum Process {
        case stopped(generation: Int)
        case running(ScriptInstance, generation: Int, tasks: [Int: Task<Void, Never>])

        var generation: Int {
            switch self {
            case .stopped(let generation), .running(_, let generation, _): generation
            }
        }
    }

    /// What it follows ends with it. (Its code's tasks hold it while they run, so none outlive it.)
    deinit {
        for follower in followers.values { follower.task.cancel() }
    }

    public init(actorSystem: ClusterSystem, dependency nature: ObjectNature) async throws {
        self.actorSystem = actorSystem
        self.nature = nature
        try await actorSystem.journal.register(actor: self, with: Self.persistenceID(for: nature))
        rehub()
        refollow()
    }

    /// The object `nature` says, a reference that reaches it wherever and whenever it runs.
    public static func resolve(on system: ClusterSystem, nature: ObjectNature) async throws -> DynamicObject {
        try await system.virtualActors.getActor(identifiedBy: actorID(for: nature), dependency: nature)
    }

    /// Its virtual actor's id: its scope's and its own, so the same identity in two scopes is two
    /// objects.
    static func actorID(for nature: ObjectNature) -> VirtualActorID {
        VirtualActorID(rawValue: "\(actorIDPrefix)\(nature.scope.name)/\(nature.identity.rawValue)")
    }

    /// Its id, as objects are known, and calls through it: its virtual actor's.
    private var objectID: ObjectID { .virtual(Self.actorID(for: nature)) }

    private static let actorIDPrefix = "dynamic-object:"

    /// The identity of the object a reference with `id` is to: `nil` for a reference to another
    /// kind of actor. A reference kept from before a restart, or made on another node, is another
    /// ID with the same identity.
    public static func identity(of id: ClusterSystem.ActorID) -> ObjectIdentity? {
        guard let virtual = id.virtualActorID?.rawValue, virtual.hasPrefix(actorIDPrefix),
            let slash = virtual.dropFirst(actorIDPrefix.count).firstIndex(of: "/")
        else { return nil }
        return ObjectIdentity(rawValue: String(virtual[virtual.index(after: slash)...]))
    }

    /// The identity of the object of `scope` a reference with `id` is to: `nil` for one of another
    /// scope, or another kind of actor.
    public static func identity(of id: ClusterSystem.ActorID, in scope: ObjectScope) -> ObjectIdentity? {
        let prefix = "\(actorIDPrefix)\(scope.name)/"
        guard let virtual = id.virtualActorID?.rawValue, virtual.hasPrefix(prefix) else { return nil }
        return ObjectIdentity(rawValue: String(virtual.dropFirst(prefix.count)))
    }

    static func persistenceID(for nature: ObjectNature) -> String {
        "turgai-object-\(nature.scope.name)/\(nature.identity.rawValue)"
    }

    /// Which object this is: its own, kept across restarts, unlike its actor ID.
    public distributed var identity: ObjectIdentity { nature.identity }

    public func handleEvent(_ event: DynamicObjectEvent) {
        state = state.applying(event)
    }

    // MARK: Lifecycle

    /// The object of `scope` with `id`, of the type whose actor is `type`, as code names it with
    /// `Type(id:)`: the one there is, a built-in one checked in under it, or one made now running
    /// its type's code. The same id is the
    /// same object, whoever names it; one of another type is refused.
    static func make(
        _ type: ObjectTypeName, id identity: ObjectIdentity, in scope: ObjectScope, on system: ClusterSystem
    ) async throws
        -> ActorReference
    {
        let object = try await resolve(on: system, nature: ObjectNature(identity: identity, scope: scope))
        if let existing = try? await object.source {
            guard existing.type == type.rawValue else {
                throw CodeProblem("`\(identity)` is a `\(existing.type)`, not a `\(type)`.")
            }
        } else if let builtIn = try await ObjectNames.object(
            named: identity.rawValue, in: scopes(around: scope), using: system)
        {
            // A built-in object, the one of its kind, is reached as it checked in.
            guard builtIn.description.type == type.rawValue else {
                throw CodeProblem("`\(identity)` is a `\(builtIn.description.type)`, not a `\(type)`.")
            }
            return try ActorReference(builtIn.object)
        } else {
            let declared = try await DynamicObjects.resolve(on: system, scope: scope).type(declaring: type)
            try await object.adopt(declared.id, code: declared.code)
        }
        return try ActorReference(object)
    }

    /// Runs `code` of the type `type` from its next message on, once it isn't handling one: the
    /// way a new module reaches an Erlang process. What it holds stays its own; data new to it
    /// starts as the code has it, and the objects its `init()` makes there are made now.
    distributed func adopt(_ type: BehaviorID, code: Script) async throws {
        let live = try state.live
        guard let scope = CallChain.current?.scope else { throw CallOnBehalfOfNoOne(actor: objectID) }
        var starts = try await ScriptInstance.starts(code, as: nature.identity)
        for (field, value) in starts where live.fields[field] == nil {
            starts[field] = try await Self.making(value, in: nature.scope, on: actorSystem)
        }
        try await emit(event: live.adopting(type, code, starts: starts, by: scope))
        stop()
        rehub()
        refollow()
    }

    /// The new version `code` of the type `type`: it runs it, if it's of that type, and passes it
    /// on to the objects it holds, which pass it on to theirs. `reached` are the objects it has
    /// reached already, so objects holding each other each take it once.
    distributed func typeChanged(_ type: BehaviorID, code: Script, reached: Set<ObjectIdentity>) async throws -> Set<
        ObjectIdentity
    > {
        var reached = reached
        guard reached.insert(nature.identity).inserted, case .live(let live) = state else { return reached }
        if live.type == type { try await adopt(type, code: code) }
        for value in try state.live.fields.values {
            for held in ObjectReference.all(in: value) {
                guard case .actor(let reference, _) = held,
                    let identity = Self.identity(of: try reference.actorID(using: actorSystem)),
                    !reached.contains(identity)
                else { continue }
                reached = try await Self.resolve(id: try reference.actorID(using: actorSystem), using: actorSystem)
                    .typeChanged(type, code: code, reached: reached)
            }
        }
        return reached
    }

    /// Gives it its name and what it was made for, once: what an object made by name has.
    distributed func describe(name: String, description: String?) async throws {
        try await emit(event: try state.live.describing(name: name, description: description))
    }

    /// Sets values of its own data, for it alone: other objects of its type keep theirs.
    public distributed func set(values: [String: JSONValue]) async throws {
        try await emit(event: try state.live.setting(values))
        stop()
        refollow()
    }

    /// Starts it if it isn't running: being called is what starts a virtual actor, and starting
    /// follows what it subscribes to again.
    distributed func start() {}

    /// It runs while it's living, so what it follows keeps reaching it.
    public func shouldDeactivate() async -> Bool {
        if case .live = state { false } else { true }
    }

    /// Ends the object for good: it answers nothing from now on, and the next idle sweep stops
    /// it, which takes it out of the catalog.
    distributed func remove() async throws {
        try await emit(event: try state.removing())
        stop()
        rehub()
        refollow()
    }

    /// Its stable reference: the one to know it by.
    public distributed var stableReference: DynamicObject {
        get async throws { try await reference() }
    }

    /// Its own reference, which keeps reaching it after it restarts: what it passes on as `self`.
    private func reference() async throws -> DynamicObject {
        try await Self.resolve(on: actorSystem, nature: nature)
    }

    /// `value` with each object its code's `init()` makes, not made yet, made now.
    private static func making(_ value: JSONValue, in scope: ObjectScope, on system: ClusterSystem) async throws
        -> JSONValue
    {
        if case .unmade(let type, let id)? = ObjectReference(value) {
            return try ObjectReference.actor(try await make(type, id: id, in: scope, on: system), type: type.rawValue)
                .json
        }
        switch value {
        case .object(let members):
            var made: [String: JSONValue] = [:]
            for (key, member) in members { made[key] = try await making(member, in: scope, on: system) }
            return .object(made)
        case .array(let items):
            var made: [JSONValue] = []
            for item in items { made.append(try await making(item, in: scope, on: system)) }
            return .array(made)
        default:
            return value
        }
    }

    // MARK: DiscoverableActor
    //
    // Every requirement is implemented `async`: a sync implementation can be bypassed by the
    // library's async `invoke` overloads (https://github.com/swiftlang/swift/issues/92795).

    /// Its code, for changing it.
    public distributed var source: Script {
        get throws { try state.live.running }
    }

    /// The type it runs.
    public distributed var type: BehaviorID? {
        get throws { try state.live.type }
    }

    /// Whoever it was made by: on whose behalf it was first given code.
    public distributed var maker: CallScope? {
        get throws { try state.live.maker }
    }

    /// What it's called, when it was made by name.
    public distributed var name: String? {
        get throws { try state.live.name }
    }

    /// Whether its code is working, and why not when it isn't.
    public distributed var health: Health {
        get throws { try state.live.health }
    }

    /// What happened to it lately, newest first.
    public distributed var recent: [Happening] {
        get throws { try state.live.recent }
    }

    public distributed func describe() async throws -> ObjectDescription {
        let object = try state.live
        let code = try object.running
        return try code.spec(description: object.description, holding: object.fields)
    }

    static func schema(of value: JSONValue) -> [String: JSONValue] {
        if ObjectReference(value) != nil { return ["x-actor-reference": true] }
        switch value {
        case .array: return ["type": "array"]
        case .string: return ["type": "string"]
        case .bool: return ["type": "boolean"]
        case .integer, .unsignedInteger: return ["type": "integer"]
        case .number: return ["type": "number"]
        case .object: return ["type": "object"]
        case .null: return [:]
        }
    }

    public distributed func read(property name: String) async throws -> JSONValue {
        guard let value = try state.live.fields[name] else {
            throw DiscoveryError.unknownProperty(name)
        }
        return value
    }

    public distributed func _subscribe(_ subscriber: UUID, to event: String) async throws {
        try hub.subscribe(subscriber, to: event)
    }

    public distributed func _nextEvent(for subscriber: UUID) async throws -> _EventDelivery {
        await hub.next(for: subscriber)
    }

    public distributed func _unsubscribe(_ subscriber: UUID) async throws {
        hub.unsubscribe(subscriber)
    }

    /// A hub for the events its code announces now, after its code changed: none for an object
    /// that isn't living.
    private func rehub() {
        let announced: Set<String> =
            if case .live(let object) = state, let code = object.code, let shape = try? ObjectShape(code) {
                Set(shape.events.map(\.name))
            } else { [] }
        hub = _DiscoveryEventHub(events: announced)
    }

    // MARK: Messages

    /// Handles a message the way its code says: its method runs on its instance, what it holds
    /// that changed is journaled, and its reply comes back.
    @discardableResult
    public distributed func invoke(_ action: String, arguments: JSONValue, through type: String?) async throws
        -> JSONValue
    {
        try await respond(action, arguments: arguments, through: type).reply
    }

    /// Handles a message as ``invoke(_:arguments:)`` does, with what its code printed, in the chain
    /// of calls it came through. A message that fails is journaled with why, and stops its code,
    /// to start again from what's journaled.
    /// It runs only as its type: a call made through another type isn't for it. One made through a
    /// protocol, `any Shop.RefundManager`, is for any object taking the message.
    public distributed func respond(
        _ action: String, arguments: JSONValue, through type: String? = nil
    ) async throws -> ObjectReply {
        let code = try state.live.running
        if let type, !type.hasPrefix("any "), type != code.type {
            throw DynamicObjectError.notA(type, isA: code.type)
        }
        return try await handling(
            action, arguments: arguments, origin: .message(Delivery(message: action, arguments: arguments, at: Date())))
    }

    /// Handles `action` with `arguments`, run by `origin`: a message, or an event of an object it
    /// follows. What it changed is journaled, then what it announced, which its subscribers get.
    private func handling(_ action: String, arguments: JSONValue, origin: Origin) async throws
        -> ObjectReply
    {
        try state.live.taking(action)
        let instance: ScriptInstance
        let reply: ObjectReply
        let after: [String: JSONValue]
        do {
            instance = try await running()
            // Its code handles the message in the chain the message came in, entered.
            reply = try await CallChain.$current.withValue(try CallChain.entering(objectID)) {
                try await instance.handle(action, arguments: arguments)
            }
            after = try await instance.fields()
        } catch {
            stop()
            try await emit(event: .failed(origin, problem: String(describing: error)))
            throw error
        }
        if let event = try state.live.handling(origin, holding: after) { try await emit(event: event) }
        try await announce(reply.announced)
        refollow()
        return ObjectReply(
            reply: try Self.replacingSelf(in: reply.reply, with: try await me(), as: try state.live.running.type),
            printed: reply.printed,
            announced: reply.announced)
    }

    /// Journals each event it announced, then hands it to its subscribers.
    private func announce(_ announcements: [Announcement]) async throws {
        for announcement in announcements {
            try await emit(event: .announced(announcement))
            hub.announce(announcement.values, named: announcement.event)
        }
    }

    // MARK: Its code

    /// Its instance, started from what's journaled if it isn't running. Calling another object
    /// from its code is calling that object, whose reply the call returns.
    private func running() async throws -> ScriptInstance {
        if case .running(let instance, _, _) = process { return instance }
        let object = try state.live
        let code = try object.running
        let me = try await me()
        let nature = nature
        let scopes = Self.scopes(around: nature.scope)
        let system = actorSystem
        let generation = process.generation + 1
        let started = try await ScriptInstance.start(
            code, as: nature.identity, holding: object.fields,
            reaches: { recipient, request in
                let callee = try await Self.recipient(recipient, me: me, scopes: scopes, using: system)
                switch (request, callee) {
                case (.call(let message, let arguments, let type), .made(let callee)):
                    return try await callee.respond(
                        message, arguments: try Self.replacingSelf(in: arguments, with: me, as: code.type),
                        through: type
                    ).reply
                case (.call(let message, let arguments, let type), .other(let callee)):
                    return try await callee.invoke(
                        message, arguments: try Self.replacingSelf(in: arguments, with: me, as: code.type),
                        through: type)
                // What a built-in object publishes; an object made here only answers messages.
                case (.read(let name), .other(let callee)):
                    return try await callee.read(property: name)
                case (.read(let name), .made(let callee)):
                    return try await callee.read(property: name)
                }
            },
            // An object its code names by id is the one of its scope with that id.
            makes: { type, id in
                .actor(try await DynamicObject.make(type, id: id, in: nature.scope, on: system), type: type.rawValue)
            },
            schedules: { [self] id in Task { await self.whenLocal { $0.startTask(id, of: generation) } } },
            cancels: { [self] id in Task { await self.whenLocal { $0.cancelTask(id, of: generation) } } })
        // Another message may have started it while this one waited.
        if case .running(let instance, _, _) = process { return instance }
        process = .running(started, generation: generation, tasks: [:])
        return started
    }

    /// Stops its code: the next message starts it again from what's journaled, and the tasks it
    /// started are gone with it.
    private func stop() {
        if case .running(_, _, let tasks) = process {
            for task in tasks.values { task.cancel() }
        }
        process = .stopped(generation: process.generation)
    }

    /// Starts the task its code started as `id`, on this actor, as a Swift task inherits the actor
    /// it's made on. What it changes is journaled; when it fails, that's journaled, and its code
    /// stops.
    private func startTask(_ id: Int, of generation: Int) {
        guard case .running(let instance, generation, var tasks) = process else { return }
        tasks[id] = Task {
            let origin = Origin.task(at: Date())
            do {
                // A task's starter doesn't wait on it: its calls start a chain of their own, on
                // behalf of whoever made it.
                let chain = try CallChain.start(try state.live.startedBy).entering(objectID)
                let announced = try await CallChain.$current.withValue(chain) {
                    try await instance.runTask(id)
                }
                let after = try await instance.fields()
                taskEnded(id, of: generation)
                if let event = try state.live.handling(origin, holding: after) { try await emit(event: event) }
                try await announce(announced)
                refollow()
            } catch {
                taskEnded(id, of: generation)
                guard case .running(_, generation, _) = process else { return }
                stop()
                try? await emit(event: .failed(origin, problem: String(describing: error)))
            }
        }
        process = .running(instance, generation: generation, tasks: tasks)
    }

    private func cancelTask(_ id: Int, of generation: Int) {
        guard case .running(_, generation, let tasks) = process else { return }
        tasks[id]?.cancel()
    }

    private func taskEnded(_ id: Int, of generation: Int) {
        guard case .running(let instance, generation, var tasks) = process else { return }
        tasks[id] = nil
        process = .running(instance, generation: generation, tasks: tasks)
    }

    // MARK: Following

    /// Follows the objects its `@Subscribed` fields hold now: a field holding another object than
    /// before follows that one instead, and one that's gone, or a removed object, follows nothing.
    private func refollow() {
        guard case .live(let object) = state, let code = object.code, let shape = try? ObjectShape(code) else {
            for follower in followers.values { follower.task.cancel() }
            followers = [:]
            return
        }
        var wanted: [String: ObjectReference] = [:]
        for field in shape.subscriptions {
            if let held = object.fields[field].flatMap(ObjectReference.init) { wanted[field] = held }
        }
        for (field, follower) in followers where wanted[field] != follower.source {
            follower.task.cancel()
            followers[field] = nil
        }
        let handlers = Set(shape.messages.map(\.name))
        for (field, source) in wanted where followers[field] == nil {
            // It follows for as long as the object lives and its node runs: the task holds it only
            // while following, so the object can go, and the task with it.
            followers[field] = Follower(
                source: source,
                task: Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self, !self.actorSystem.isTerminated else { return }
                        guard
                            await self.whenLocal({ await $0.follow(field, holding: source, handlers: handlers) })
                                == true
                        else { return }
                        try? await Task.sleep(for: .seconds(1))
                    }
                })
        }
    }

    /// Delivers the events of the object `field` holds that the code has a method for, named like
    /// each, until they end: whether it should follow again, which a source that's gone, or not
    /// there yet, should be.
    private func follow(_ field: String, holding reference: ObjectReference, handlers: Set<String>) async -> Bool {
        do {
            _ = try state.live
            let source = try await Self.discoverable(
                reference, me: try await me(), scopes: Self.scopes(around: nature.scope), using: actorSystem)
            let events = try await source.describe().events.keys.filter { handlers.contains(Self.handler(for: $0)) }
            guard !events.isEmpty else { return false }
            let pulls = events.map { event in Task { await pull(event, from: source, into: field) } }
            await withTaskCancellationHandler {
                for pull in pulls { await pull.value }
            } onCancel: {
                for pull in pulls { pull.cancel() }
            }
        } catch {
            actorSystem.log.warning(
                "A dynamic object can't follow an object",
                metadata: ["object": "\(nature.identity)", "field": "\(field)", "error": "\(error)"])
        }
        return true
    }

    /// Subscribes to `event` of `source`, and delivers each one until it ends.
    private func pull(_ event: String, from source: DiscoverableObject, into field: String) async {
        let subscriber = UUID()
        do {
            try await source._subscribe(subscriber, to: event)
            while !Task.isCancelled {
                switch try await source._nextEvent(for: subscriber) {
                case .event(let values): await deliver(event, values: values, from: field)
                case .idle: continue
                case .ended: return
                }
            }
            try await source._unsubscribe(subscriber)
        } catch {
            actorSystem.log.warning(
                "A dynamic object's subscription ended",
                metadata: ["object": "\(nature.identity)", "event": "\(event)", "error": "\(error)"])
        }
    }

    /// An event of an object it follows, handled by its method named like it, as any message is:
    /// journaled, with what failed if it did.
    private func deliver(_ event: String, values: JSONValue, from field: String) async {
        let handler = Self.handler(for: event)
        let origin = Origin.event(Delivery(message: handler, arguments: values, at: Date()), from: field)
        do {
            // An event it follows starts a chain of its own, as a task does, on behalf of whoever
            // made it: its handling enters it.
            _ = try await CallChain.$current.withValue(.start(try state.live.startedBy)) {
                try await handling(handler, arguments: values, origin: origin)
            }
        } catch {
            // Journaled as it failed; the next event is delivered all the same.
        }
    }

    /// The function that handles `event`: on and its name, `buttonPressed`'s and `ButtonPressed`'s
    /// `onButtonPressed`.
    public static func handler(for event: String) -> String {
        "on" + event.prefix(1).uppercased() + event.dropFirst()
    }

    /// Itself, as it's passed on: its stable reference.
    private func me() async throws -> ActorReference {
        try ActorReference(try await reference())
    }

    // MARK: Calling other objects

    /// An object a call goes to: one made here, which takes the chain of calls along, or a built-in
    /// object, which doesn't.
    private enum Callee {
        case made(DynamicObject)
        case other(DiscoverableObject)
    }

    /// Who a call goes to: a living actor, an object by its name, or itself.
    private static func recipient(
        _ recipient: ObjectReference, me: ActorReference, scopes: [ObjectScope], using system: ClusterSystem
    ) async throws -> Callee {
        switch recipient {
        case .actor(let reference, _):
            return try callee(try reference.resolve(using: system), using: system)
        case .itself:
            return try callee(try me.resolve(using: system), using: system)
        case .unmade(let type, _):
            throw DynamicObjectError.noReference("a `\(type)` not made yet")
        case .named(let name, _):
            // One its scopes hold by that name, or else one that checked in under it.
            for scope in scopes {
                if let nature = try await DynamicObjects.resolve(on: system, scope: scope).object(named: name) {
                    return .made(try await DynamicObject.resolve(on: system, nature: nature))
                }
            }
            guard let found = try await ObjectNames.object(named: name, in: scopes, using: system) else {
                throw DynamicObjectError.noObjectNamed(name)
            }
            return .other(found.object)
        }
    }

    /// The object a reference is to, as any object is reached: to describe, and to subscribe to.
    private static func discoverable(
        _ reference: ObjectReference, me: ActorReference, scopes: [ObjectScope], using system: ClusterSystem
    ) async throws -> DiscoverableObject {
        switch try await recipient(reference, me: me, scopes: scopes, using: system) {
        case .made(let object): try DiscoverableObject.resolve(id: object.id, using: system)
        case .other(let object): object
        }
    }

    /// `object` as a callee: a dynamic object, as its reference says, or any other.
    private static func callee(_ object: DiscoverableObject, using system: ClusterSystem) throws -> Callee {
        guard identity(of: object.id) != nil else { return .other(object) }
        return .made(try DynamicObject.resolve(id: object.id, using: system))
    }

    /// The scopes an object of `scope` can name objects in: its own, and the machine's.
    static func scopes(around scope: ObjectScope) -> [ObjectScope] {
        switch scope {
        case .shared: [.shared]
        case .owned(let user): ObjectScope.visible(to: user)
        }
    }

    /// Itself, passed on in a value, is this object's own reference, to pass on as a reply-to.
    /// `value` with the code's own object, passing itself on, as a reference to `me`, of `type`.
    private static func replacingSelf(in value: JSONValue, with me: ActorReference, as type: String) throws -> JSONValue
    {
        if ObjectReference(value) == .itself { return try ObjectReference.actor(me, type: type).json }
        switch value {
        case .object(let members):
            return .object(try members.mapValues { try replacingSelf(in: $0, with: me, as: type) })
        case .array(let items): return .array(try items.map { try replacingSelf(in: $0, with: me, as: type) })
        default: return value
        }
    }
}

/// A message's reply, and what the object's code printed handling it.
public struct ObjectReply: Codable, Sendable, Equatable {
    public let reply: JSONValue
    public let printed: [String]
    /// The events it announced handling it.
    public let announced: [Announcement]
}

/// Which behavior an object runs, shared with every object running the same one.
public struct BehaviorID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func new() -> BehaviorID {
        BehaviorID(rawValue: UUID().uuidString.lowercased())
    }
}

/// A dynamic object's own identity, given when it's created and kept across restarts.
/// The name of a protocol an object's type declares, as code writes it: `Shop.RefundManager`.
public struct ObjectProtocolName: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// The name of an object's type, as its code declares its actor: `Counter`.
public struct ObjectTypeName: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ObjectIdentity: RawRepresentable, Hashable, Codable, CodingKeyRepresentable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A new, unique identity.
    public static func new() -> ObjectIdentity {
        ObjectIdentity(rawValue: UUID().uuidString.lowercased())
    }

    public var description: String { rawValue }
}

/// A dynamic object in a signature, such as an object to change, is a reference to it.
extension DynamicObject: Describable {
    public static var jsonSchema: JSONValue {
        _DiscoverySupport.actorReferenceSchema
    }
}

/// An identity in a signature is its string.
extension ObjectIdentity: Describable {
    public static var jsonSchema: JSONValue {
        ["type": "string", "description": "An object's identity."]
    }
}
