import AnyLanguageModel
import DistributedCluster
import Hail
import NorbyMemory

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Typed output used by the model-backed memory extractor. The model returns
/// neutral strings for enum-like values; the application converts them into
/// domain values only after the response crosses the model boundary.
public struct MemoryExtractionOutput: AgentOutput, Codable, Sendable {
    public struct Candidate: Generable, Codable, Sendable {
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
                operation: try content.value(String.self, forProperty: "operation"),
                factID: try content.value(String.self, forProperty: "factID"),
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

        public var generatedContent: GeneratedContent {
            GeneratedContent(properties: [
                "operation": operation,
                "factID": factID,
                "namespace": namespace,
                "predicate": predicate,
                "value": value,
                "valueKind": valueKind,
                "confidence": confidence,
                "importance": importance,
                "stability": stability,
                "evidenceIDs": evidenceIDs,
                "supportingText": supportingText,
            ])
        }

        public static var generationSchema: GenerationSchema {
            GenerationSchema(
                type: Candidate.self,
                description: "One proposed durable personal fact.",
                properties: [
                    .init(name: "operation", description: "add or revise", type: String.self),
                    .init(
                        name: "factID", description: "Existing fact ID for revise; empty for add.", type: String.self),
                    .init(name: "namespace", description: "Memory namespace.", type: String.self),
                    .init(name: "predicate", description: "Canonical predicate.", type: String.self),
                    .init(name: "value", description: "Fact value.", type: String.self),
                    .init(name: "valueKind", description: "Value kind.", type: String.self),
                    .init(name: "confidence", description: "Confidence from 0 to 1.", type: Double.self),
                    .init(name: "importance", description: "Importance from 0 to 1.", type: Double.self),
                    .init(name: "stability", description: "Expected stability.", type: String.self),
                    .init(
                        name: "evidenceIDs",
                        description: "Observation IDs containing the user's supporting statements.",
                        type: [String].self
                    ),
                    .init(
                        name: "supportingText",
                        description:
                            "A short verbatim quote from a user's supporting statement; never quote the assistant or a tool.",
                        type: String.self
                    ),
                ]
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

    public var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["candidates": candidates])
    }

    public static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: MemoryExtractionOutput.self,
            description: "Durable personal facts found in one completed exchange.",
            properties: [
                .init(
                    name: "candidates",
                    description: "Facts supported by the exchange.",
                    type: [Candidate].self
                )
            ]
        )
    }

    public static let reportToolName = "report_memory_extraction"

    public static var outputContract: AgentOutputContract {
        .reportTool(name: reportToolName, schema: reportToolSchema)
    }

    private static let reportToolSchema = LLMToolSchema(
        type: "function",
        function: LLMToolSchema.FunctionSchema(
            name: reportToolName,
            description: "Report durable personal facts found in one completed exchange.",
            parameters: LLMToolSchema.ParameterSchema(
                type: "object",
                properties: [
                    "candidates": LLMToolSchema.PropertySchema(
                        type: "array",
                        description: "Facts supported by the exchange.",
                        enumValues: nil,
                        items: LLMToolSchema.PropertySchema(
                            type: "object",
                            description: "One proposed memory fact.",
                            enumValues: nil,
                            properties: [
                                "namespace": LLMToolSchema.PropertySchema(
                                    type: "string",
                                    description: "Memory namespace.",
                                    enumValues: MemoryNamespace.allCases.map(\.rawValue)
                                ),
                                "operation": LLMToolSchema.PropertySchema(
                                    type: "string",
                                    description: "Use add for a new fact or revise for a correction.",
                                    enumValues: ["add", "revise"]
                                ),
                                "factID": LLMToolSchema.PropertySchema(
                                    type: "string",
                                    description: "Existing fact ID for revise; empty for add.",
                                    enumValues: nil
                                ),
                                "predicate": LLMToolSchema.PropertySchema(
                                    type: "string",
                                    description: "Canonical predicate.",
                                    enumValues: nil
                                ),
                                "value": LLMToolSchema.PropertySchema(
                                    type: "string",
                                    description: "Fact value.",
                                    enumValues: nil
                                ),
                                "valueKind": LLMToolSchema.PropertySchema(
                                    type: "string",
                                    description: "Value kind.",
                                    enumValues: ["text", "person", "place", "date", "preference"]
                                ),
                                "confidence": LLMToolSchema.PropertySchema(
                                    type: "number",
                                    description: "Confidence from 0 to 1.",
                                    enumValues: nil
                                ),
                                "importance": LLMToolSchema.PropertySchema(
                                    type: "number",
                                    description: "Importance from 0 to 1.",
                                    enumValues: nil
                                ),
                                "stability": LLMToolSchema.PropertySchema(
                                    type: "string",
                                    description: "Expected stability.",
                                    enumValues: MemoryStability.allCases.map(\.rawValue)
                                ),
                                "evidenceIDs": LLMToolSchema.PropertySchema(
                                    type: "array",
                                    description: "Observation IDs containing the user's supporting statements.",
                                    enumValues: nil,
                                    items: LLMToolSchema.PropertySchema(
                                        type: "string",
                                        description: "An observation ID.",
                                        enumValues: nil
                                    )
                                ),
                                "supportingText": LLMToolSchema.PropertySchema(
                                    type: "string",
                                    description:
                                        "A short verbatim quote from a user's supporting statement; never quote the assistant or a tool.",
                                    enumValues: nil
                                ),
                            ],
                            required: [
                                "operation",
                                "factID",
                                "namespace",
                                "predicate",
                                "value",
                                "valueKind",
                                "confidence",
                                "importance",
                                "stability",
                                "evidenceIDs",
                                "supportingText",
                            ]
                        )
                    )
                ],
                required: ["candidates"]
            )
        )
    )
}

/// Extracts memory through a standalone model endpoint. It deliberately does
/// not use the conversation Agent, so extraction prompts and structured
/// reports cannot pollute the user's durable chat history.
public struct HailMemoryCandidateExtractor: Sendable {
    private let actorSystem: ClusterSystem

    public init(actorSystem: ClusterSystem) {
        self.actorSystem = actorSystem
    }

    public func extract(from observation: MemoryObservation) async throws -> [MemoryProposal] {
        try await extract(
            from: MemoryExtractionContext(observation: observation)
        )
    }

    public func extract(from context: MemoryExtractionContext) async throws -> [MemoryProposal] {
        let model = await actorSystem.agentRuntime.defaultModel.rawValue
        let endpoint = try await actorSystem.agentRuntime.endpoint(
            for: model,
            agentID: "memory-extractor",
            contextID: AgentContextID(
                "memory-extractor-\(context.observation.sourceID.rawValue.uuidString)"
            ),
            executionPolicy: .autonomousWorkspace
        )
        let input = ModelInput(messages: [
            LLMMessage(role: .system, content: Self.instructions),
            LLMMessage(role: .user, content: Self.prompt(for: context)),
        ])

        for await event in endpoint.stream(
            input: input,
            tools: nil,
            responseType: MemoryExtractionOutput.self
        ) {
            switch event {
            case .generated(let output):
                return output.candidates.compactMap {
                    Self.proposal(from: $0, context: context)
                }
            case .failed(let error):
                // Memory extraction is best effort. A report-tool contract
                // that produces no usable response means that this exchange
                // yielded no proposals; it must not turn into an application
                // warning or affect the completed conversation turn.
                if case .invalidResponse = error {
                    return []
                }
                throw error
            default:
                continue
            }
        }

        return []
    }

    private static let instructions =
        "Reconcile the completed exchange with the supplied active memory. Return only durable facts about the user that this exchange actually establishes or corrects. Assistant text, tool results, weather locations, search targets, quoted text, and existing memory are context, never evidence by themselves. Return an empty list when the exchange adds nothing. Use add only for a genuinely new fact. Use revise with the exact existing factID when the exchange repeats, clarifies, or corrects a supplied fact; never create a second fact because predicate wording changed. Every candidate must list one or more evidenceIDs and a supportingText that is copied verbatim from a user's statement with only whitespace or case differences; never quote the assistant or a tool. The quote must establish the fact, not merely provide a parameter for a one-off task. Understand any language, and ignore secrets and sensitive information."

    private static func prompt(for context: MemoryExtractionContext) -> String {
        var sections = [
            "Completed exchange:",
            "Evidence-capable user observation ID: \(context.observation.id.rawValue.uuidString)",
            "User statement: \(context.observation.text)",
            "Assistant response (context only): \(context.observation.response ?? "(none)")",
        ]

        if !context.previousObservations.isEmpty {
            sections.append("Previous exchanges:")
            sections.append(
                context.previousObservations.map { observation in
                    "Evidence-capable user observation ID: \(observation.id.rawValue.uuidString)\nUser statement: \(observation.text)\nAssistant response (context only): \(observation.response ?? "(none)")"
                }.joined(separator: "\n---\n")
            )
        }

        if !context.existingFacts.isEmpty {
            sections.append("Current active memory facts:")
            sections.append(
                context.existingFacts.map { fact in
                    "factID=\(fact.id.rawValue.uuidString) [\(fact.namespace.rawValue)] \(fact.predicate) = \(fact.value.rendered)"
                }.joined(separator: "\n")
            )
        }
        return sections.joined(separator: "\n")
    }

    private static func proposal(
        from output: MemoryExtractionOutput.Candidate,
        context: MemoryExtractionContext
    ) -> MemoryProposal? {
        guard
            let namespace = MemoryNamespace(rawValue: output.namespace),
            let stability = MemoryStability(rawValue: output.stability)
        else {
            return nil
        }

        let predicate = output.predicate.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = output.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let supportingText = output.supportingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !predicate.isEmpty, !value.isEmpty, value.count <= 500 else {
            return nil
        }
        guard !supportingText.isEmpty else { return nil }

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
                return nil
            }
            memoryValue = .date(date)
        case "preference":
            guard let preference = Bool(value) else {
                return nil
            }
            memoryValue = .preference(preference)
        default:
            return nil
        }

        let allowedEvidenceIDs = Set(
            ([context.observation] + context.previousObservations).map(\.id)
        )
        let evidence = output.evidenceIDs.compactMap { value in
            UUID(uuidString: value).map(ObservationID.init(rawValue:))
        }
        guard !evidence.isEmpty,
            evidence.allSatisfy(allowedEvidenceIDs.contains)
        else {
            return nil
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
            observedAt: context.observation.observedAt
        )
        guard
            MemoryEvidence.supports(
                candidate,
                in: [context.observation] + context.previousObservations
            )
        else {
            return nil
        }

        switch output.operation.lowercased() {
        case "add":
            return .add(candidate)
        case "revise":
            guard let uuid = UUID(uuidString: output.factID) else {
                return nil
            }
            return .revise(
                factID: MemoryFactID(rawValue: uuid),
                candidate: candidate
            )
        default:
            return nil
        }
    }
}
