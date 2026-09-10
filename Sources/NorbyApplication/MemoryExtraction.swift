import AnyLanguageModel
import DistributedCluster
import Hail
import NorbyMemory

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum ExtractionError: Error, Sendable, Equatable {
    case missingReport
    case invalidReport(String)
    case invalidCandidate
}

/// Typed output used by the model-backed memory extractor. The model returns
/// neutral strings for enum-like values; the application converts them into
/// domain values only after the response crosses the model boundary.
public struct MemoryExtractionOutput: Codable, Sendable {
    public struct Candidate: Codable, Sendable, ConvertibleFromGeneratedContent {
        public let operation: String
        public let factID: String
        public let namespace: String
        public let predicate: String
        public let value: String
        public let valueKind: String
        public let confidence: Double
        public let importance: Double
        public let stability: String
        public let evidenceIDs: [String]
        public let supportingText: String

        public init(
            operation: String = "add",
            factID: String = "",
            namespace: String,
            predicate: String,
            value: String,
            valueKind: String,
            confidence: Double,
            importance: Double,
            stability: String,
            evidenceIDs: [String] = [],
            supportingText: String = ""
        ) {
            self.operation = operation
            self.factID = factID
            self.namespace = namespace
            self.predicate = predicate
            self.value = value
            self.valueKind = valueKind
            self.confidence = confidence
            self.importance = importance
            self.stability = stability
            self.evidenceIDs = evidenceIDs
            self.supportingText = supportingText
        }

        public init(_ content: GeneratedContent) throws {
            self.init(
                operation: try content.value(String?.self, forProperty: "operation") ?? "add",
                factID: try content.value(String?.self, forProperty: "factID") ?? "",
                namespace: try content.value(String.self, forProperty: "namespace"),
                predicate: try content.value(String.self, forProperty: "predicate"),
                value: try content.value(String.self, forProperty: "value"),
                valueKind: try content.value(String.self, forProperty: "valueKind"),
                confidence: try content.value(Double.self, forProperty: "confidence"),
                importance: try content.value(Double.self, forProperty: "importance"),
                stability: try content.value(String.self, forProperty: "stability"),
                evidenceIDs: try content.value([String].self, forProperty: "evidenceIDs"),
                supportingText: try content.value(String.self, forProperty: "supportingText")
            )
        }

    }

    public let candidates: [Candidate]

    public init(candidates: [Candidate]) {
        self.candidates = candidates
    }

    public init(_ content: GeneratedContent) throws {
        self.candidates = try content.value([Candidate].self, forProperty: "candidates")
    }

    static let reportToolName = "report_memory_extraction"

    static func reportToolDefinition() throws -> ToolDefinition {
        let candidate = DynamicGenerationSchema(
            name: "MemoryCandidate",
            description: "One proposed durable personal fact.",
            properties: [
                .init(
                    name: "operation", description: "add or revise; omit for add.",
                    schema: DynamicGenerationSchema(name: "MemoryOperation", anyOf: ["add", "revise"]), isOptional: true
                ),
                .init(
                    name: "factID", description: "Existing fact ID for revise; omit for add.",
                    schema: DynamicGenerationSchema(type: String.self), isOptional: true),
                .init(
                    name: "namespace", description: "The memory namespace.",
                    schema: DynamicGenerationSchema(
                        name: "MemoryNamespace", anyOf: MemoryNamespace.allCases.map(\.rawValue))),
                .init(
                    name: "predicate", description: "Canonical predicate.",
                    schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "value", description: "Fact value.", schema: DynamicGenerationSchema(type: String.self)),
                .init(
                    name: "valueKind", description: "How to interpret the value.",
                    schema: DynamicGenerationSchema(
                        name: "MemoryValueKind", anyOf: ["text", "person", "place", "date", "preference"])),
                .init(
                    name: "confidence", description: "Confidence from 0 to 1.",
                    schema: DynamicGenerationSchema(type: Double.self)),
                .init(
                    name: "importance", description: "Importance from 0 to 1.",
                    schema: DynamicGenerationSchema(type: Double.self)),
                .init(
                    name: "stability", description: "Expected stability.",
                    schema: DynamicGenerationSchema(
                        name: "MemoryStability", anyOf: MemoryStability.allCases.map(\.rawValue))),
                .init(
                    name: "evidenceIDs", description: "Observation IDs containing the user's supporting statements.",
                    schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))),
                .init(
                    name: "supportingText", description: "A short verbatim quote from a user's supporting statement.",
                    schema: DynamicGenerationSchema(type: String.self)),
            ]
        )
        let output = try GenerationSchema(
            root: DynamicGenerationSchema(
                name: "MemoryExtractionOutput",
                description: "Durable personal facts found in one completed exchange.",
                properties: [
                    .init(
                        name: "candidates", description: "Facts supported by the exchange.",
                        schema: DynamicGenerationSchema(arrayOf: candidate))
                ]
            ),
            dependencies: []
        )
        return ToolDefinition(
            name: reportToolName,
            description: "Report durable personal facts found in one completed exchange.",
            parameters: output
        )
    }
}

/// Extracts memory through a standalone model endpoint. It deliberately does
/// not use the conversation Agent, so extraction prompts and structured
/// reports cannot pollute the user's durable chat history.
public struct HailMemoryCandidateExtractor: Sendable {
    private let actorSystem: ClusterSystem
    private let reportTool: ToolDefinition

    public init(actorSystem: ClusterSystem) throws {
        self.actorSystem = actorSystem
        self.reportTool = try MemoryExtractionOutput.reportToolDefinition()
    }

    public func extract(from input: ExtractionInput) async throws -> [MemoryProposal] {
        guard let firstObservation = input.observations.first else {
            throw ExtractionError.missingReport
        }
        let model = await actorSystem.agentRuntime.defaultModel.rawValue
        // Extraction is structured reconciliation, not conversation: request
        // non-thinking generation so background work stays cheap. The
        // endpoint is cached per effort level, so conversational turns keep
        // the model's default reasoning.
        let endpoint = try await actorSystem.agentRuntime.endpoint(
            for: model,
            agentID: "memory-extractor",
            contextID: AgentContextID(
                "memory-extractor-\(firstObservation.sourceID.rawValue.uuidString)"
            ),
            executionPolicy: .autonomousWorkspace,
            reasoningEffort: ReasoningEffort.none
        )
        let modelInput = ModelInput(messages: [
            LLMMessage(role: .system, content: Self.instructions),
            LLMMessage(role: .user, content: Self.prompt(for: input)),
        ])

        for await event in endpoint.stream(
            input: modelInput,
            tools: [reportTool]
        ) {
            try Task.checkCancellation()
            switch event {
            case .toolCall(let call) where call.name == MemoryExtractionOutput.reportToolName:
                do {
                    let output = try MemoryExtractionOutput(
                        try GeneratedContent(json: call.arguments.json)
                    )
                    return try output.candidates.map { try Self.proposal(from: $0, input: input) }
                } catch {
                    throw ExtractionError.invalidReport(String(describing: error))
                }
            case .toolCall:
                continue
            case .failed(let error):
                throw error
            case .generated:
                throw ExtractionError.missingReport
            default:
                continue
            }
        }

        try Task.checkCancellation()
        throw ExtractionError.missingReport
    }

    private static let instructions =
        "Reconcile the completed exchange with the supplied active memory. Return only durable facts about the user that this exchange actually establishes or corrects. Assistant text, tool results, weather locations, search targets, quoted text, and existing memory are context, never evidence by themselves. Return an empty list when the exchange adds nothing. Use add only for a genuinely new fact. Use revise with the exact existing factID when the exchange repeats, clarifies, or corrects a supplied fact; never create a second fact because predicate wording changed. Every candidate must list one or more evidenceIDs and a supportingText that is copied verbatim from a user's statement with only whitespace or case differences; never quote the assistant or a tool. The quote must establish the fact, not merely provide a parameter for a one-off task. Understand any language, and ignore secrets and sensitive information."

    private static func prompt(for input: ExtractionInput) -> String {
        var sections = ["Conversation window in chronological order:"]
        sections.append(
            input.chronologicalObservations.map { observation in
                "Evidence-capable user observation ID: \(observation.id.rawValue.uuidString)\nUser statement: \(observation.text)\nAssistant response (context only): \(observation.response ?? "(none)")"
            }.joined(separator: "\n---\n")
        )

        if !input.existingFacts.isEmpty {
            sections.append("Current active memory facts:")
            sections.append(
                input.existingFacts.map { fact in
                    "factID=\(fact.id.rawValue.uuidString) [\(fact.namespace.rawValue)] \(fact.predicate) = \(fact.value.rendered)"
                }.joined(separator: "\n")
            )
        }
        return sections.joined(separator: "\n")
    }

    private static func proposal(
        from output: MemoryExtractionOutput.Candidate,
        input: ExtractionInput
    ) throws -> MemoryProposal {
        guard
            let namespace = MemoryNamespace(rawValue: output.namespace),
            let stability = MemoryStability(rawValue: output.stability)
        else {
            throw ExtractionError.invalidCandidate
        }

        let predicate = output.predicate.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = output.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let supportingText = output.supportingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !predicate.isEmpty, !value.isEmpty, value.count <= 500 else {
            throw ExtractionError.invalidCandidate
        }
        guard !supportingText.isEmpty else { throw ExtractionError.invalidCandidate }

        let memoryValue: MemoryValue
        switch output.valueKind {
        case "text":
            memoryValue = .text(value)
        case "person":
            memoryValue = .person(value)
        case "place":
            memoryValue = .place(value)
        case "date":
            guard let date = ISO8601DateFormatter().date(from: value) else {
                throw ExtractionError.invalidCandidate
            }
            memoryValue = .date(date)
        case "preference":
            guard let preference = Bool(value) else {
                throw ExtractionError.invalidCandidate
            }
            memoryValue = .preference(preference)
        default:
            throw ExtractionError.invalidCandidate
        }

        let allowedEvidenceIDs = Set(
            (input.observations + input.previousObservations).map(\.id)
        )
        let evidence = try output.evidenceIDs.map { value in
            guard let uuid = UUID(uuidString: value) else {
                throw ExtractionError.invalidCandidate
            }
            return ObservationID(rawValue: uuid)
        }
        guard !evidence.isEmpty,
            evidence.allSatisfy(allowedEvidenceIDs.contains)
        else {
            throw ExtractionError.invalidCandidate
        }

        guard let observedAt = input.observations.last?.observedAt else {
            throw ExtractionError.invalidCandidate
        }

        let candidate = FactCandidate(
            namespace: namespace,
            predicate: predicate,
            value: memoryValue,
            evidence: evidence,
            supportingText: supportingText,
            confidence: output.confidence,
            importance: output.importance,
            stability: stability,
            observedAt: observedAt
        )
        guard
            MemoryEvidence.supports(
                candidate,
                in: input.observations + input.previousObservations
            )
        else {
            throw ExtractionError.invalidCandidate
        }

        switch output.operation.lowercased() {
        case "add":
            return .add(candidate)
        case "revise":
            guard let uuid = UUID(uuidString: output.factID) else {
                throw ExtractionError.invalidCandidate
            }
            return .revise(
                factID: MemoryFactID(rawValue: uuid),
                candidate: candidate
            )
        default:
            throw ExtractionError.invalidCandidate
        }
    }
}
