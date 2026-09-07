import Hail
import NorbyDomain
import NorbyMemory

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Lets the model propose a durable user-specific memory update.
///
/// It is scoped to the current user and observation by the application
/// composition root, then applies proposals through Norby's memory actor.
public struct MemoryTool: Tool {
    public enum Operation: String, Codable, Sendable, Equatable, CaseIterable {
        case add
        case revise
    }

    public enum Namespace: String, Codable, Sendable, Equatable, CaseIterable {
        case profile
        case preference
        case relationship
        case project
        case environment
    }

    public enum ValueKind: String, Codable, Sendable, Equatable, CaseIterable {
        case text
        case person
        case place
        case date
        case preference
    }

    public enum Stability: String, Codable, Sendable, Equatable, CaseIterable {
        case transient
        case situational
        case mutable
        case stable
    }

    public struct Input: Codable, Sendable {
        public let operation: Operation
        public let factID: String?
        public let namespace: Namespace
        public let predicate: String
        public let value: String
        public let valueKind: ValueKind
        public let supportingText: String
        public let confidence: Double
        public let importance: Double
        public let stability: Stability

        private enum CodingKeys: String, CodingKey {
            case operation
            case factID = "fact_id"
            case namespace
            case predicate
            case value
            case valueKind = "value_kind"
            case supportingText = "supporting_text"
            case confidence
            case importance
            case stability
        }

        public init(
            operation: Operation = .add,
            factID: String? = nil,
            namespace: Namespace,
            predicate: String,
            value: String,
            valueKind: ValueKind = .text,
            supportingText: String,
            confidence: Double = 0.9,
            importance: Double = 0.5,
            stability: Stability = .mutable
        ) {
            self.operation = operation
            self.factID = factID
            self.namespace = namespace
            self.predicate = predicate
            self.value = value
            self.valueKind = valueKind
            self.supportingText = supportingText
            self.confidence = confidence
            self.importance = importance
            self.stability = stability
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.operation = try container.decodeIfPresent(Operation.self, forKey: .operation) ?? .add
            self.factID = try container.decodeIfPresent(String.self, forKey: .factID)
            self.namespace = try container.decode(Namespace.self, forKey: .namespace)
            self.predicate = try container.decode(String.self, forKey: .predicate)
            self.value = try container.decode(String.self, forKey: .value)
            self.valueKind = try container.decode(ValueKind.self, forKey: .valueKind)
            self.supportingText = try container.decode(String.self, forKey: .supportingText)
            self.confidence = try container.decode(Double.self, forKey: .confidence)
            self.importance = try container.decode(Double.self, forKey: .importance)
            self.stability = try container.decode(Stability.self, forKey: .stability)
        }
    }

    public let name = "memory"
    public let description =
        "Add or revise a durable, user-specific fact established by the user's message. supporting_text must be copied from that message, never from an assistant reply or tool result. Use add for a new fact and revise with the exact fact_id shown in memory context when correcting an existing fact. Do not store one-off task parameters, secrets, credentials, or sensitive information."

    private let userID: NorbyDomain.UserID
    private let observation: MemoryObservation
    private let expectedGeneration: MemoryGeneration?

    public init(
        userID: NorbyDomain.UserID,
        observation: MemoryObservation,
        expectedGeneration: MemoryGeneration? = nil
    ) {
        self.userID = userID
        self.observation = observation
        self.expectedGeneration = expectedGeneration
    }

    public var schema: LLMToolSchema {
        LLMToolSchema(
            type: "function",
            function: LLMToolSchema.FunctionSchema(
                name: name,
                description: description,
                parameters: LLMToolSchema.ParameterSchema(
                    type: "object",
                    properties: [
                        "namespace": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "Memory category.",
                            enumValues: Namespace.allCases.map(\.rawValue)
                        ),
                        "operation": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "Use add for a new fact or revise to correct the fact identified by fact_id.",
                            enumValues: Operation.allCases.map(\.rawValue)
                        ),
                        "fact_id": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "The existing memory fact ID. Required for revise; omit for add.",
                            enumValues: nil
                        ),
                        "predicate": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "A short stable property name, for example name, home, or likes.",
                            enumValues: nil
                        ),
                        "value": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "The value to remember.",
                            enumValues: nil
                        ),
                        "value_kind": LLMToolSchema.PropertySchema(
                            type: "string",
                            description: "How to interpret the value.",
                            enumValues: ValueKind.allCases.map(\.rawValue)
                        ),
                        "supporting_text": LLMToolSchema.PropertySchema(
                            type: "string",
                            description:
                                "A short verbatim quote from the user's message that establishes the fact; never quote the assistant or a tool.",
                            enumValues: nil
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
                            description: "How likely the fact is to change.",
                            enumValues: Stability.allCases.map(\.rawValue)
                        ),
                    ],
                    required: [
                        "operation",
                        "namespace",
                        "predicate",
                        "value",
                        "value_kind",
                        "supporting_text",
                        "confidence",
                        "importance",
                        "stability",
                    ]
                )
            )
        )
    }

    public func effect(for input: Input) throws -> CoordinationEffect {
        try validate(input)
        return CoordinationEffect(subsystem: "memory", action: input.operation.rawValue)
    }

    public func run(
        input: Input,
        token: borrowing EffectToken<CoordinationEffect>
    ) async throws -> String {
        _ = token
        try validate(input)
        let proposal = try proposal(from: input)
        let user = try await ActorSystemDependency.current.virtualActors.resolveUser(userID)
        let update = try await user.applyMemoryProposal(
            proposal,
            observation: observation,
            expectedGeneration: expectedGeneration
        )
        switch (update.newFactCount, update.updatedFactCount) {
        case (0, 0):
            return "No memory was changed."
        case (let newCount, 0):
            return newCount == 1
                ? "Noted down 1 fact."
                : "Noted down \(newCount) facts."
        case (0, let updatedCount):
            return updatedCount == 1
                ? "Updated 1 existing fact."
                : "Updated \(updatedCount) existing facts."
        default:
            return "Noted down \(update.newFactCount) facts and updated \(update.updatedFactCount) existing facts."
        }
    }

    private func validate(_ input: Input) throws {
        guard !input.predicate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.missingArgument("predicate")
        }
        guard !input.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.missingArgument("value")
        }
        guard !input.supportingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.missingArgument("supporting_text")
        }
        guard input.confidence.isFinite, (0...1).contains(input.confidence) else {
            throw ToolError.invalidArgument("confidence", value: String(input.confidence))
        }
        guard input.importance.isFinite, (0...1).contains(input.importance) else {
            throw ToolError.invalidArgument("importance", value: String(input.importance))
        }

        switch input.operation {
        case .add:
            guard input.factID == nil else {
                throw ToolError.invalidArgument("fact_id", value: "fact_id is only used for revise")
            }
        case .revise:
            guard let factID = input.factID,
                !factID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ToolError.missingArgument("fact_id")
            }
        }
    }

    private func proposal(from input: Input) throws -> MemoryProposal {
        let predicate = input.predicate.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = input.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let supportingText = input.supportingText.trimmingCharacters(in: .whitespacesAndNewlines)

        let memoryValue: MemoryValue
        switch input.valueKind {
        case .text:
            memoryValue = .text(value)
        case .person:
            memoryValue = .person(value)
        case .place:
            memoryValue = .place(value)
        case .date:
            guard let date = ISO8601DateFormatter().date(from: value) else {
                throw ToolError.invalidArgument("value", value: value)
            }
            memoryValue = .date(date)
        case .preference:
            guard let preference = Bool(value) else {
                throw ToolError.invalidArgument("value", value: value)
            }
            memoryValue = .preference(preference)
        }

        guard let namespace = MemoryNamespace(rawValue: input.namespace.rawValue),
            let stability = MemoryStability(rawValue: input.stability.rawValue)
        else {
            throw ToolError.invalidArgument("namespace", value: input.namespace.rawValue)
        }
        let candidate = FactCandidate(
            namespace: namespace,
            predicate: predicate,
            value: memoryValue,
            evidence: [observation.id],
            supportingText: supportingText,
            confidence: input.confidence,
            importance: input.importance,
            stability: stability,
            observedAt: observation.observedAt
        )

        switch input.operation {
        case .add:
            return .add(candidate)
        case .revise:
            guard let factID = input.factID,
                let uuid = UUID(uuidString: factID)
            else {
                throw ToolError.invalidArgument("fact_id", value: input.factID ?? "")
            }
            return .revise(
                factID: MemoryFactID(rawValue: uuid),
                candidate: candidate
            )
        }
    }
}

public typealias RememberTool = MemoryTool
