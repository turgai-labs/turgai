import AnyLanguageModel
import Hail
import TurgaiDomain

/// A conversation's name, as its agent's model gives it.
@Generable(description: "A name for a conversation.")
public struct ConversationName: Codable, Sendable {
    @Guide(description: "What the conversation is about, in a few words.")
    public let title: String
}

/// Names a conversation from one exchange in it: one request to its agent's model, apart from the
/// turn.
public enum ConversationNamingService {
    private static let task = "Name this conversation."

    /// What the model at `endpoint` names a conversation in which `said` was answered with
    /// `answered`.
    public static func name(endpoint: any ModelEndpoint, said: String, answered: String) async throws
        -> ConversationName
    {
        let entries: [Transcript.Entry] = [
            .instructions(.init(segments: [.text(.init(content: task))], toolDefinitions: [])),
            .prompt(.init(segments: [.text(.init(content: "user: \(said)\nassistant: \(answered)"))])),
        ]
        let stream = endpoint.stream(
            request: ModelRequest(input: entries, entries: entries),
            tools: [],
            authority: FullAuthority(),
            generating: ConversationName.self,
            purpose: .generation
        )
        for await event in stream {
            switch event {
            case .generated(let name):
                return name
            case .failed(let error):
                throw AgentRuntimeError.modelMisbehavior(String(describing: error))
            default:
                continue
            }
        }
        throw AgentRuntimeError.modelMisbehavior("Naming the conversation produced no name")
    }
}
