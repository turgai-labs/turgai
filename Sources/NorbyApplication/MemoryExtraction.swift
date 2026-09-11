import AnyLanguageModel
import DistributedCluster
import Hail
import NorbyMemory

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

private let memoryReportToolName = "report_memory_extraction"

public enum ExtractionError: Error, Sendable, Equatable {
    case missingReport
    case invalidReport(String)
    case invalidCandidate
}

/// Typed output used by the model-backed memory extractor. The model returns
/// neutral strings for enum-like values; the application converts them into
/// domain values only after the response crosses the model boundary.
@Generable
public struct MemoryExtractionOutput: Codable, Sendable {
    @Generable
    public struct Candidate: Codable, Sendable {
        @Guide(description: "add for a new fact, revise when correcting an existing fact")
        public let operation: String
        @Guide(description: "The existing fact identifier for revise; omit for add")
        public let factID: String?
        @Guide(description: "The memory namespace")
        public let namespace: String
        @Guide(description: "The canonical fact predicate")
        public let predicate: String
        @Guide(description: "The fact value")
        public let value: String
        @Guide(description: "text, person, place, date, or preference")
        public let valueKind: String
        public let confidence: Double
        public let importance: Double
        @Guide(description: "transient, situational, mutable, or stable")
        public let stability: String
        public let evidenceIDs: [String]
        public let supportingText: String
    }

    public let candidates: [Candidate]

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
            name: memoryReportToolName,
            description: "Report durable personal facts found in one completed exchange.",
            parameters: output
        )
    }
}

/// Extracts memory through a standalone model endpoint when context compaction
/// asks for it. It deliberately does not use the conversation Agent, so
/// extraction prompts and structured reports cannot pollute the user's durable
/// chat history. Conversation turns never invoke this extractor directly.
public struct HailMemoryCandidateExtractor: Sendable {
    private let actorSystem: ClusterSystem

    public init(actorSystem: ClusterSystem) {
        self.actorSystem = actorSystem
    }

    public func extract(from input: ExtractionInput) async throws -> [MemoryProposal] {
        guard let firstObservation = input.observations.first else {
            throw ExtractionError.missingReport
        }
        let model = await actorSystem.agentRuntime.defaultModel.rawValue
        // Extraction is structured reconciliation, not conversation: request
        // non-thinking generation. The endpoint is cached per effort level,
        // so conversational turns keep the model's default reasoning.
        let endpoint = try await actorSystem.agentRuntime.endpoint(
            for: model,
            agentID: "memory-extractor",
            contextID: AgentContextID(
                "memory-extractor-\(firstObservation.sourceID.rawValue.uuidString)"
            ),
            executionPolicy: .autonomousWorkspace,
            reasoningEffort: ReasoningEffort.none
        )
        let entries: [Transcript.Entry] = [
            .instructions(
                .init(
                    segments: [.text(.init(content: Self.instructions))],
                    toolDefinitions: []
                )
            ),
            .prompt(.init(segments: [.text(.init(content: Self.prompt(for: input)))])),
        ]

        for await event in endpoint.stream(
            request: ModelRequest(input: input, entries: entries),
            tools: [],
            authority: FullAuthority(),
            generating: MemoryExtractionOutput.self,
            purpose: .generation
        ) {
            try Task.checkCancellation()
            switch event {
            case .toolsRequested:
                throw ExtractionError.invalidReport(
                    "Memory extraction must produce structured output, not a tool call.")
            case .generated(let output):
                do {
                    return try output.candidates.map { try Self.proposal(from: $0, input: input) }
                } catch {
                    throw ExtractionError.invalidReport(String(describing: error))
                }
            case .failed(let error):
                throw error
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
            guard let factID = output.factID,
                let uuid = UUID(uuidString: factID)
            else {
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
