import DistributedCluster
import Hail
import TurgaiDomain
import TurgaiObjects

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What every effect made on this node may do, an agent's turn or an object's code alike: what the
/// scope of the call allows, as its group settled it when the chain started. An exact request
/// reaching outside runs when the scope allows it, and is refused otherwise, saying exactly what
/// it was: whoever opened the scope asks its group. What Turgai's own objects, schedules and memory
/// are asked is theirs to check, so it's granted here.
public struct TurgaiAuthority: Authority {
    public init() {}

    public func decision<Effect: ScopedEffect>(on effect: Effect) -> EffectDecision {
        if let composite = effect as? any CompositeScopedEffect { return composite.decision(using: self) }
        if let request = Self.exactRequest(effect) {
            guard let scope = CallChain.current?.scope else { return .denied("it's on behalf of no one") }
            return scope.allows(request) ? .granted : .denied(request.refusal)
        }
        guard Self.checkedWhereTheyGo.contains(ObjectIdentifier(Effect.self)) else {
            return .denied("the '\(effect.name)' effect is not granted by this authority")
        }
        return .granted
    }

    /// The exact request an effect is, when it reaches outside: to the web, a file, a command or a
    /// program.
    static func exactRequest(_ effect: some ScopedEffect) -> ExactRequest? {
        switch effect {
        case let network as NetworkEffect:
            .http(method: network.request.method, url: network.request.url, body: network.request.body ?? Data())
        case let file as FileEffect:
            switch file.action {
            case .read: .readFile(path: file.path)
            case .list: .listFiles(path: file.path)
            case .write: .writeFile(path: file.path, content: file.content ?? "")
            }
        case let terminal as TerminalEffect:
            .command(terminal.command, arguments: terminal.arguments, in: terminal.cwd)
        case let process as ProcessEffect:
            .program(
                process.executable, arguments: process.arguments,
                in: process.cwd ?? FileManager.default.currentDirectoryPath)
        default:
            nil
        }
    }

    /// The effects whose own callee checks the call: objects, by what they allow; a conversation's
    /// schedules, timers and attachments, and a person's memory, by whose they are; and reading
    /// the clock, which reaches nothing.
    private static let checkedWhereTheyGo: Set<ObjectIdentifier> = [
        ObjectIdentifier(FindObjectsEffect.self), ObjectIdentifier(ListObjectsEffect.self),
        ObjectIdentifier(MakeObjectEffect.self), ObjectIdentifier(EditObjectEffect.self),
        ObjectIdentifier(ShareObjectEffect.self), ObjectIdentifier(UseObjectEffect.self),
        ObjectIdentifier(RemoveObjectEffect.self), ObjectIdentifier(InvokeObjectEffect.self),
        ObjectIdentifier(ToolPageEffect.self), ObjectIdentifier(RecallEffect.self),
        ObjectIdentifier(CreateScheduleEffect.self), ObjectIdentifier(ReplaceScheduleEffect.self),
        ObjectIdentifier(CancelScheduleEffect.self), ObjectIdentifier(ListSchedulesEffect.self),
        ObjectIdentifier(TriggerScheduleEffect.self), ObjectIdentifier(CreateTimerEffect.self),
        ObjectIdentifier(ReplaceTimerEffect.self), ObjectIdentifier(CancelTimerEffect.self),
        ObjectIdentifier(ListTimersEffect.self), ObjectIdentifier(UserWorkflowEffect.self),
        ObjectIdentifier(AttachmentEffect.self), ObjectIdentifier(CoordinationEffect.self),
        ObjectIdentifier(ClockEffect.self),
    ]
}
