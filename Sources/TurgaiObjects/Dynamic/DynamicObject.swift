import AttributedCalls
import DiscoverableActors
import Distributed
import DistributedCluster
import DurableWorkflows
import EventSourcing
import Foundation
import RunningActors
import ScopedEffect
import TurgaiCalls
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
public distributed actor DynamicObject: DiscoverableActor, AccessControlled {
    public typealias ActorSystem = ClusterSystem
    public typealias Dependency = Config
    public typealias Event = DynamicObjectEvent
    public typealias State = DynamicObjectState

    public var state = DynamicObjectState.unmade
    /// Which object it is, kept across restarts.
    private let own: ObjectIdentity
    /// The space it's in, whose every caller is: given, never kept in its state.
    private let home: SpaceID
    /// Its code: stopped, or running as an instance started from what's journaled. It stops when
    /// its code changes or a message fails, as an Erlang process restarts from its last state.
    private var process = Process.stopped(generation: 0)
    /// Its subscribers, to the events the code it runs announces: replaced with each new code, so
    /// subscribers find theirs ended, and subscribe again.
    private var hub = _DiscoveryEventHub(events: [])
    /// The objects it follows, by the `@Subscribed` field holding each.
    private var followers: [String: Follower] = [:]
    /// The schedules its `Schedule` fields are due by, as they're kept durably now, by field.
    private var scheduled: [String: Schedule] = [:]
    /// The timers its `Timer` fields are due at, as they're kept durably now, by field.
    private var timed: [String: Timer] = [:]
    /// Keeping its schedules as its fields say, one change after another.
    private var rescheduling: Task<Void, Never>?
    /// Its code as the checker read it, once for each code it runs.
    private var checked: CheckedScript?

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

    /// Which object it is, and the space it's in.
    public struct Config: Codable, Hashable, Sendable {
        public let space: SpaceID
        public let identity: ObjectIdentity
    }

    public init(actorSystem: ClusterSystem, dependency: Config) async throws {
        self.actorSystem = actorSystem
        self.own = dependency.identity
        self.home = dependency.space
        try await actorSystem.journal.register(
            actor: self, with: Self.persistenceID(for: dependency.identity, in: dependency.space))
        rehub()
        refollow()
    }

    /// How an object that kept work running is brought back as a node starts: its kept work is its
    /// own, as a reminder is its actor's, so it's reached as itself, and its space says then what
    /// it may do.
    public static let recovery = RunningActors.Recovery.of(
        DynamicObject.self, dependency: Config.self, keptFor: Config.self
    ) { object, config, _ in
        try await Call.asWork(of: actorID(for: config.identity, in: config.space)) {
            try await object.recovered()
        }
    }

    /// The object `identity` of `space`, by its id: a reference that reaches it wherever and
    /// whenever it runs. Finding it isn't using it: each call is put to its space.
    public static func identified(by identity: ObjectIdentity, in space: SpaceID, on system: ClusterSystem)
        async throws -> DynamicObject
    {
        try await system.virtualActors.getActor(
            identifiedBy: actorID(for: identity, in: space), dependency: Config(space: space, identity: identity))
    }

    /// Its virtual actor's id: its space's, then its identity there.
    static func actorID(for identity: ObjectIdentity, in space: SpaceID) -> VirtualActorID {
        .owned(by: space, actorKind, identity.rawValue)
    }

    /// The actor the made object `identity` of `space` is, as calls reach it: the same across
    /// restarts.
    public static func callActor(for identity: ObjectIdentity, in space: SpaceID) -> CallActor {
        .virtual(actorID(for: identity, in: space))
    }

    /// Its id, as objects are known, and calls through it: its virtual actor's.
    private var objectID: ObjectID { .virtual(Self.actorID(for: own, in: home)) }

    private static let actorKind = "object"

    /// The space and identity of the made object a virtual actor id is: none for another kind of
    /// actor.
    private static func made(_ virtual: VirtualActorID) -> (space: SpaceID, identity: ObjectIdentity)? {
        guard let owned = virtual.owned, owned.kind == actorKind else { return nil }
        return (owned.space, ObjectIdentity(rawValue: owned.name))
    }

    /// The identity of the object a reference with `id` is to: `nil` for a reference to another
    /// kind of actor. A reference kept from before a restart, or made on another node, is another
    /// ID with the same identity.
    public static func identity(of id: ClusterSystem.ActorID) -> ObjectIdentity? {
        id.virtualActorID.flatMap(made)?.identity
    }

    /// The space of the made object a reference with `id` is to: `nil` for another kind of actor.
    public static func space(of id: ClusterSystem.ActorID) -> SpaceID? {
        id.virtualActorID.flatMap(made)?.space
    }

    /// The identity of the made object `objectID` is, if it's one.
    static func identity(of objectID: ObjectID) -> ObjectIdentity? {
        guard case .virtual(let id) = objectID else { return nil }
        return made(id)?.identity
    }

    static func persistenceID(for identity: ObjectIdentity, in space: SpaceID) -> String {
        "turgai-object-\(space.rawValue.uuidString)-\(identity.rawValue)"
    }

    /// The object whose journal is `persistenceID`, and its space: none for another's journal.
    public static func object(persistedAs persistenceID: String) -> (space: SpaceID, identity: ObjectIdentity)? {
        let prefix = "turgai-object-"
        guard persistenceID.hasPrefix(prefix) else { return nil }
        let rest = persistenceID.dropFirst(prefix.count)
        guard rest.count > 37, let space = UUID(uuidString: String(rest.prefix(36))) else { return nil }
        return (SpaceID(rawValue: space), ObjectIdentity(rawValue: String(rest.dropFirst(37))))
    }

    /// Which object this is: its own, kept across restarts, unlike its actor ID.
    public distributed var identity: ObjectIdentity { own }

    public func handleEvent(_ event: DynamicObjectEvent) {
        state = state.applying(event)
    }

    // MARK: Lifecycle

    /// The object with `id`, of the type whose actor is `type`, as code names it with `Type(id:)`:
    /// the one there is, a built-in one checked in under it, or one made now running its type's
    /// code. The same id is the same object, whoever names it; one of another type is refused. A
    /// page is its space's by its name, made the first time.
    static func make(
        _ type: ObjectTypeName, id identity: ObjectIdentity, in space: SpaceID, on system: ClusterSystem
    ) async throws
        -> ActorReference
    {
        if type.rawValue == Page.describe().type {
            guard let name = PageName(rawValue: identity.rawValue) else {
                throw CodeProblem(
                    "`\(identity)` isn't a page's name: lowercase letters, digits and `-`, not at either end.")
            }
            return try ActorReference(try await DynamicObjects.of(space, on: system).page(named: name))
        }
        let object = try await identified(by: identity, in: space, on: system)
        if let existing = try? await object.source {
            guard existing.type == type.rawValue else {
                throw CodeProblem("`\(identity)` is a `\(existing.type)`, not a `\(type)`.")
            }
        } else if let builtIn = try await ObjectNames.object(named: identity.rawValue, in: space, using: system) {
            // A built-in object, the one of its kind, is reached as it checked in.
            guard builtIn.description.type == type.rawValue else {
                throw CodeProblem("`\(identity)` is a `\(builtIn.description.type)`, not a `\(type)`.")
            }
            return try ActorReference(builtIn.object)
        } else {
            let declared = try await DynamicObjects.of(space, on: system).type(declaring: type)
            try await object.adopt(declared.id, code: declared.code)
        }
        return try ActorReference(object)
    }

    /// Runs `code` of the type `type` from its next message on, once it isn't handling one: the
    /// way a new module reaches an Erlang process. What it holds stays its own; data new to it
    /// starts as the code has it, and the objects its `init()` makes there are made now.
    distributed func adopt(_ type: BehaviorID, code: Script) async throws {
        let held = try state.held
        let chain = try caller()
        var starts = try await ScriptInstance.starts(code, as: own)
        // What its code makes as it starts is made by a call from it, so it holds what it makes.
        for (field, value) in starts where held[field] == nil {
            starts[field] = try await Self.making(value, in: home, on: actorSystem)
        }
        try await emit(event: try state.adopting(type, code, starts: starts, by: chain))
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
        guard reached.insert(own).inserted, case .live(let live) = state else { return reached }
        if live.type == type { try await adopt(type, code: code) }
        // It passes the code on to what it holds itself: only it may change what its code made.
        _ = try caller()
        for value in try state.live.fields.values {
            for held in ObjectReference.all(in: value) {
                guard case .actor(let reference, _) = held,
                    let identity = Self.identity(of: try reference.actorID(using: actorSystem)),
                    !reached.contains(identity)
                else { continue }
                let object = try Self.resolve(id: try reference.actorID(using: actorSystem), using: actorSystem)
                reached = try await object.typeChanged(type, code: code, reached: reached)
            }
        }
        return reached
    }

    /// Gives it its name and what it was made for, once: what an object made by name has.
    distributed func describe(name: String, description: String?) async throws {
        try await emit(event: try state.live.describing(name: name, description: description, by: try caller()))
    }

    /// Sets values of its own data, for it alone: other objects of its type keep theirs.
    public distributed func set(values: [String: JSONValue]) async throws {
        try await emit(event: try state.live.setting(values, by: try caller()))
        stop()
        refollow()
    }

    /// Starts it if it isn't running: being called is what starts a virtual actor, and starting
    /// follows what it subscribes to again.
    distributed func start() {}

    /// Brought back after a restart, as it was running: started again, so it follows again, and
    /// its code's tasks run.
    public distributed func recovered() async throws {
        _ = try await running()
    }

    /// It runs while it's living, so what it follows keeps reaching it.
    public func shouldDeactivate() async -> Bool {
        if case .live = state { false } else { true }
    }

    /// Ends the object for good: it answers nothing from now on, and the next idle sweep stops
    /// it, which takes it out of the catalog.
    distributed func remove() async throws {
        // Its schedules and timers end with it, whether or not this activation kept them.
        let schedules = (try? shape(of: state.live.code))?.schedules ?? []
        let timers = (try? state.live.fields).map { timers(in: $0) } ?? [:]
        try await emit(event: try state.removing(by: try caller()))
        stop()
        rehub()
        refollow()
        if let workflows = workflows {
            for property in schedules {
                let id = ObjectFiring.scheduleID(of: own, in: home, property)
                try? await workflows.cancelSchedule(id: id, workflow: ObjectScheduleWorkflow.self)
                await actorSystem.tellTasks(in: home, .ended(.schedule(id)))
            }
            for (property, timer) in timers {
                let id = ObjectFiring.timerID(of: own, in: home, property, at: timer.date)
                try? await workflows.cancel(type: ObjectTimerWorkflow.self, options: WorkflowOptions(id: id))
                await actorSystem.tellTasks(in: home, .ended(.timer(id)))
            }
        }
    }

    /// Its `property`'s schedule is due: its code's `on<Property>Fired(at:)` handles it as its own
    /// doing, as an event it follows is handled.
    distributed func fired(_ property: String) async throws {
        let handler = Schedule.handler(for: property)
        let arguments: JSONValue = ["at": .string(Date.now.ISO8601Format())]
        let origin = Origin.event(Delivery(message: handler, arguments: arguments, at: Date()), from: property)
        _ = try await asItsOwn {
            try await handling(handler, arguments: arguments, origin: origin)
        }
    }

    /// Its stable reference: the one to know it by.
    public distributed var stableReference: DynamicObject {
        get async throws { try await reference() }
    }

    /// Its own reference, which keeps reaching it after it restarts: what it passes on as `self`.
    private func reference() async throws -> DynamicObject {
        try await Self.identified(by: own, in: home, on: actorSystem)
    }

    /// `value` with each object its code's `init()` makes, not made yet, made now.
    private static func making(_ value: JSONValue, in space: SpaceID, on system: ClusterSystem) async throws
        -> JSONValue
    {
        if case .unmade(let type, let id)? = ObjectReference(value) {
            return try ObjectReference.actor(try await make(type, id: id, in: space, on: system), type: type.rawValue)
                .json
        }
        switch value {
        case .object(let members):
            var made: [String: JSONValue] = [:]
            for (key, member) in members { made[key] = try await making(member, in: space, on: system) }
            return .object(made)
        case .array(let items):
            var made: [JSONValue] = []
            for item in items { made.append(try await making(item, in: space, on: system)) }
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
        get throws { try state.live.code }
    }

    /// The type it runs.
    public distributed var type: BehaviorID {
        get throws { try state.live.type }
    }

    /// The conversation it was made in, when it was made in one.
    public distributed var madeIn: ConversationID? {
        get throws { try state.live.madeIn }
    }

    /// Who may read it and who may write it.
    public distributed var access: Access {
        get throws { try state.live.access }
    }

    /// Gives `audience` `level` of access, or takes all of it away: only a call on behalf of
    /// someone who may write it does.
    public distributed func share(with audience: Audience, _ level: AccessLevel?) async throws {
        try await emit(event: try state.live.sharing(with: audience, level, by: try caller()))
        // Who it's listed to follows who may read it.
        try await DynamicObjects.of(home, on: actorSystem).accessChanged(own)
    }

    // MARK: Who may call it

    /// Who may read it and who may write it, for a call through `chain`: one not made yet is the
    /// caller's to make.
    public distributed func access(for chain: CallChain) -> Access {
        state.access(for: chain)
    }

    /// The call it's handling: every call is on someone's behalf.
    private func caller() throws -> Reached {
        try Reached.current(at: objectID.callActor)
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
        return try checked(object.code).spec(description: object.description, holding: object.fields)
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
            if case .live(let object) = state, let shape = try? ObjectShape(object.code) {
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
        let code = try state.live.code
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
            // Its code handles the message with what the call it came in may do.
            _ = try caller()
            reply = try await instance.handle(action, arguments: arguments)
            after = try await instance.fields()
            // A schedule it holds is one that can be due: one that can't is its code's problem.
            _ = try schedules(in: after)
        } catch let refusal as EffectDenied {
            // Its scope didn't allow what its code needed: that isn't the code failing. What the
            // message did is undone, as for any message that doesn't finish.
            stop()
            throw refusal
        } catch {
            stop()
            try await emit(event: .failed(origin, problem: String(describing: error)))
            throw error
        }
        if let event = try state.live.handling(origin, holding: after) { try await emit(event: event) }
        try await announce(reply.announced)
        refollow()
        return ObjectReply(
            reply: try Self.replacingSelf(in: reply.reply, with: try await me(), as: try state.live.code.type),
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
        let code = object.code
        let me = try await me()
        let system = actorSystem
        let space = home
        let generation = process.generation + 1
        let started = try await ScriptInstance.start(
            code, as: own, holding: object.fields,
            reaches: { recipient, request in
                let callee = try await Self.recipient(recipient, me: me, in: space, using: system)
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
            // An object its code names by id is the one with that id.
            makes: { type, id in
                .actor(try await DynamicObject.make(type, id: id, in: space, on: system), type: type.rawValue)
            },
            // A tool's function, run here, in the chain of the call its code is handling.
            tools: { function, input in try await system.toolsAPI.call(function, with: input, on: system) },
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

    /// Starts the task its code started as `id`, kept going by its node: it comes back with the
    /// object after a restart. What it changes is journaled; when it fails, that's journaled, and
    /// its code stops.
    private func startTask(_ id: Int, of generation: Int) {
        guard case .running(let instance, generation, var tasks) = process else { return }
        let config = Config(space: home, identity: own)
        tasks[id] = actorSystem.runningActors.keep(
            DynamicObject.self, id: Self.actorID(for: own, in: home), dependency: config, for: config
        ) { [weak self] in
            await self?.whenLocal { await $0.runTask(id, of: generation) }
        }
        process = .running(instance, generation: generation, tasks: tasks)
    }

    /// The task its code started as `id`, run on this actor, as its own doing: none once its code
    /// stopped or changed.
    private func runTask(_ id: Int, of generation: Int) async {
        guard case .running(let instance, generation, _) = process else { return }
        let origin = Origin.task(at: Date())
        do {
            // A task's starter doesn't wait on it: its calls start a chain of their own, the
            // object's own work, which may what its space says now.
            // What it needs that isn't allowed, whoever decides refuses, and asks who may allow it.
            let announced = try await asItsOwn { try await instance.runTask(id) }
            let after = try await instance.fields()
            taskEnded(id, of: generation)
            if let event = try state.live.handling(origin, holding: after) { try await emit(event: event) }
            try await announce(announced)
            refollow()
        } catch is EffectDenied {
            // Not its code failing: what the task did is undone.
            taskEnded(id, of: generation)
            guard case .running(_, generation, _) = process else { return }
            stop()
        } catch {
            taskEnded(id, of: generation)
            guard case .running(_, generation, _) = process else { return }
            stop()
            try? await emit(event: .failed(origin, problem: String(describing: error)))
        }
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
        rescheduleSoon()
        guard case .live(let object) = state, let shape = try? shape(of: object.code) else {
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
            let config = Config(space: home, identity: own)
            followers[field] = Follower(
                source: source,
                // Kept going by its node: it comes back with the object after a restart.
                task: actorSystem.runningActors.keep(
                    DynamicObject.self, id: Self.actorID(for: own, in: home), dependency: config, for: config
                ) { [weak self] in
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

    /// Its code's shape: read once for each code, which reading resolves with the checker.
    private func shape(of code: Script) throws(CodeProblem) -> ObjectShape {
        try checked(code).shape
    }

    /// `code` as the checker reads it: read again only when it's other code than last time.
    private func checked(_ code: Script) throws(CodeProblem) -> CheckedScript {
        if let checked, checked.script == code { return checked }
        let read = try CheckedScript(code)
        checked = read
        return read
    }

    // MARK: Schedules

    /// The durable workflows, when its node runs them.
    private var workflows: DurableWorkflowsPlugin? {
        actorSystem.settings.plugins[DurableWorkflowsPlugin.pluginKey]
    }

    /// The schedules `fields` hold, by field, each one that can be due: one that can't is refused.
    private func schedules(in fields: [String: JSONValue]) throws -> [String: Schedule] {
        guard case .live(let object) = state, let shape = try? shape(of: object.code) else { return [:] }
        var held: [String: Schedule] = [:]
        for property in shape.schedules {
            guard let value = fields[property], value != .null else { continue }
            let schedule = try value.decode(Schedule.self)
            _ = try schedule.rule()
            held[property] = schedule
        }
        return held
    }

    /// The timers `fields` hold, by field.
    private func timers(in fields: [String: JSONValue]) -> [String: Timer] {
        guard case .live(let object) = state, let shape = try? shape(of: object.code) else { return [:] }
        var held: [String: Timer] = [:]
        for property in shape.timers {
            guard let value = fields[property], value != .null, let timer = try? value.decode(Timer.self) else {
                continue
            }
            held[property] = timer
        }
        return held
    }

    /// Keeps its schedules as its fields say, after whatever changed before.
    private func rescheduleSoon() {
        let before = rescheduling
        rescheduling = Task { [weak self] in
            await before?.value
            await self?.whenLocal { await $0.reschedule() }
        }
    }

    /// Each `Schedule` field it holds has its durable schedule: made when it's set, made again
    /// when it changes, and cancelled when it's `nil`, gone, or the object is.
    private func reschedule() async {
        guard let workflows else { return }
        let wanted: [String: Schedule]
        let wantedTimers: [String: Timer]
        let living: Bool
        let place: ConversationID?
        if case .live(let object) = state {
            wanted = (try? schedules(in: object.fields)) ?? [:]
            wantedTimers = timers(in: object.fields)
            living = true
            place = object.madeIn
        } else {
            wanted = [:]
            wantedTimers = [:]
            living = false
            place = nil
        }
        for (property, schedule) in wanted where scheduled[property] != schedule {
            guard living else { continue }
            let id = ObjectFiring.scheduleID(of: own, in: home, property)
            do {
                // One that changed is made again: a schedule that's there keeps what it was made with.
                if scheduled[property] != nil {
                    try await workflows.cancelSchedule(id: id, workflow: ObjectScheduleWorkflow.self)
                }
                try await workflows.schedule(
                    id: id, recurrence: try schedule.rule(), workflow: ObjectScheduleWorkflow.self,
                    input: ObjectFiring(
                        object: own, property: property, space: home,
                        due: .schedule(schedule), place: place),
                    overlapPolicy: .skip)
                scheduled[property] = schedule
                await actorSystem.tellTasks(
                    in: home,
                    .kept(
                        KeptTask(
                            id: .schedule(id), of: .object(own, field: property), due: .schedule(schedule),
                            paused: false)))
            } catch {
                actorSystem.log.warning(
                    "A dynamic object's schedule couldn't be kept",
                    metadata: ["object": "\(own)", "field": "\(property)", "error": "\(error)"])
            }
        }
        for property in scheduled.keys where wanted[property] == nil {
            let id = ObjectFiring.scheduleID(of: own, in: home, property)
            try? await workflows.cancelSchedule(id: id, workflow: ObjectScheduleWorkflow.self)
            scheduled[property] = nil
            if living { await actorSystem.tellTasks(in: home, .ended(.schedule(id))) }
        }
        // A timer is started for each date it's set to: one that fired, or runs, is left as it is.
        for (property, timer) in wantedTimers where timed[property] != timer {
            guard living else { continue }
            do {
                if let before = timed[property] {
                    let id = ObjectFiring.timerID(of: own, in: home, property, at: before.date)
                    try? await workflows.cancel(type: ObjectTimerWorkflow.self, options: WorkflowOptions(id: id))
                    await actorSystem.tellTasks(in: home, .ended(.timer(id)))
                }
                let id = ObjectFiring.timerID(of: own, in: home, property, at: timer.date)
                try await workflows.start(
                    type: ObjectTimerWorkflow.self, options: WorkflowOptions(id: id),
                    input: ObjectFiring(
                        object: own, property: property, space: home,
                        due: .timer(timer), place: place))
                timed[property] = timer
                // A timer that's due already fires as it starts, and isn't one any more.
                if timer.date > Date.now {
                    await actorSystem.tellTasks(
                        in: home,
                        .kept(
                            KeptTask(
                                id: .timer(id), of: .object(own, field: property), due: .timer(timer), paused: false)))
                }
            } catch {
                actorSystem.log.warning(
                    "A dynamic object's timer couldn't be kept",
                    metadata: ["object": "\(own)", "field": "\(property)", "error": "\(error)"])
            }
        }
        for (property, timer) in timed where wantedTimers[property] == nil {
            let id = ObjectFiring.timerID(of: own, in: home, property, at: timer.date)
            try? await workflows.cancel(type: ObjectTimerWorkflow.self, options: WorkflowOptions(id: id))
            timed[property] = nil
            if living { await actorSystem.tellTasks(in: home, .ended(.timer(id))) }
        }
    }

    /// `work`, done as its own: its tasks, the events it follows and what's due for it. Asked by
    /// it and starting from it, with what its space says it may do as the work starts, in the
    /// conversation it was made in.
    private func asItsOwn<Value>(_ work: () async throws -> Value) async throws -> Value {
        let scope = try await actorSystem.objectCallDecisions.opening(
            try Party(Self.actorID(for: own, in: home)), home, actorSystem)
        let chain = CallChain.start(scope, in: try state.live.madeIn)
        return try await Call.onOwnBehalf { try await CallChain.$current.withValue(chain, operation: work) }
    }

    /// Delivers the events of the object `field` holds that the code has a method for, named like
    /// each, until they end: whether it should follow again, which a source that's gone, or not
    /// there yet, should be.
    private func follow(_ field: String, holding reference: ObjectReference, handlers: Set<String>) async -> Bool {
        // Following is its own doing, as its tasks are.
        (try? await asItsOwn { await following(field, holding: reference, handlers: handlers) }) ?? false
    }

    private func following(_ field: String, holding reference: ObjectReference, handlers: Set<String>) async -> Bool {
        do {
            _ = try state.live
            let source = try await Self.discoverable(reference, me: try await me(), in: home, using: actorSystem)
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
                metadata: ["object": "\(own)", "field": "\(field)", "error": "\(error)"])
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
                metadata: ["object": "\(own)", "event": "\(event)", "error": "\(error)"])
        }
    }

    /// An event of an object it follows, handled by its method named like it, given the event's
    /// value, as any message is: journaled, with what failed if it did.
    private func deliver(_ event: String, values: JSONValue, from field: String) async {
        let handler = Self.handler(for: event)
        let arguments: JSONValue = ["_0": values]
        let origin = Origin.event(Delivery(message: handler, arguments: arguments, at: Date()), from: field)
        do {
            // An event it follows is its own work, as a task is.
            _ = try await asItsOwn { try await handling(handler, arguments: arguments, origin: origin) }
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
        _ recipient: ObjectReference, me: ActorReference, in space: SpaceID, using system: ClusterSystem
    ) async throws -> Callee {
        switch recipient {
        case .actor(let reference, _):
            return try callee(try reference.resolve(using: system), using: system)
        case .itself:
            return try callee(try me.resolve(using: system), using: system)
        case .unmade(let type, _):
            throw DynamicObjectError.noReference("a `\(type)` not made yet")
        case .named(let name, _):
            // One made by that name, or else one that checked in under it.
            if let identity = try await DynamicObjects.of(space, on: system).object(named: name) {
                return .made(try await DynamicObject.identified(by: identity, in: space, on: system))
            }
            guard let found = try await ObjectNames.object(named: name, in: space, using: system) else {
                throw DynamicObjectError.noObjectNamed(name)
            }
            return .other(found.object)
        }
    }

    /// The object a reference is to, as any object is reached: to describe, and to subscribe to.
    private static func discoverable(
        _ reference: ObjectReference, me: ActorReference, in space: SpaceID, using system: ClusterSystem
    ) async throws -> DiscoverableObject {
        switch try await recipient(reference, me: me, in: space, using: system) {
        case .made(let object): try DiscoverableObject.resolve(id: object.id, using: system)
        case .other(let object): object
        }
    }

    /// `object` as a callee: a dynamic object, as its reference says, or any other.
    private static func callee(_ object: DiscoverableObject, using system: ClusterSystem) throws -> Callee {
        guard identity(of: object.id) != nil else { return .other(object) }
        return .made(try DynamicObject.resolve(id: object.id, using: system))
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
