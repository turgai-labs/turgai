import DistributedCluster
import Hail
import TurgaiCalls
import TurgaiDomain
import TurgaiObjects
import TurgaiSpaces

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What every effect made on this node may do, an agent's turn or an object's code alike: what the
/// scope of the call allows, as its space settled it when the chain started. An exact request
/// reaching outside runs when the scope allows it, and is refused otherwise, saying exactly what
/// it was: whoever opened the scope asks its space. What Turgai's own objects, schedules and memory
/// are asked is theirs to check, so it's granted here.
public struct TurgaiAuthority: Authority {
    /// Who decides exactly a request: what the call carries, for an app with no one else deciding,
    /// or the space of whoever it's on behalf of, asked as the effect is activated.
    public enum Deciding: Sendable {
        /// From the scope the call carries, as its chain started.
        case fromTheCall
        /// By the space, as things are now: what its person may do, what's shared with them, and
        /// what's allowed once, which it spends. Refused, it asks whoever decides.
        case bySpace(ClusterSystem)
    }

    let deciding: Deciding

    public init(deciding: Deciding = .fromTheCall) {
        self.deciding = deciding
    }

    public func decision<Effect: ScopedEffect>(on effect: Effect) async -> EffectDecision {
        if let composite = effect as? any CompositeScopedEffect { return await composite.decision(using: self) }
        if let request = Self.exactRequest(effect) {
            guard let chain = CallChain.current else { return .denied("it's on behalf of no one") }
            switch deciding {
            case .fromTheCall:
                return chain.scope.allows(request) ? .granted : .denied(request.refusal)
            case .bySpace(let system):
                do {
                    let space = try await Space.identified(by: chain.scope.space, on: system)
                    switch try await space.decide(request, for: chain) {
                    case .granted: return .granted
                    case .refused: return .denied(request.refusal)
                    }
                } catch {
                    return .denied(EffectRefusal("its space couldn't decide: \(error)"))
                }
            }
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
    /// attachments, and a person's memory, by whose they are; reading the clock, which reaches
    /// nothing; and saying something in the chat the call happens in, or asking its model, which
    /// reaches no other.
    private static let checkedWhereTheyGo: Set<ObjectIdentifier> = [
        ObjectIdentifier(FindObjectsEffect.self), ObjectIdentifier(ListObjectsEffect.self),
        ObjectIdentifier(MakeObjectEffect.self), ObjectIdentifier(EditObjectEffect.self),
        ObjectIdentifier(ObjectDeclarationEffect.self), ObjectIdentifier(SaveObjectCodeEffect.self),
        ObjectIdentifier(ShareObjectEffect.self), ObjectIdentifier(UseObjectEffect.self),
        ObjectIdentifier(RemoveObjectEffect.self), ObjectIdentifier(InvokeObjectEffect.self),
        ObjectIdentifier(ToolPageEffect.self), ObjectIdentifier(RecallEffect.self),
        ObjectIdentifier(UserWorkflowEffect.self),
        ObjectIdentifier(AttachmentEffect.self), ObjectIdentifier(CoordinationEffect.self),
        ObjectIdentifier(ClockEffect.self), ObjectIdentifier(ChatSayEffect.self),
        ObjectIdentifier(ChatAskEffect.self),
    ]
}
